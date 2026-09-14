#!/usr/bin/env python3
"""Measure how hard this Mac is paging, which is what actually stalls the guest.

`host_cpu_share.py` answers "is a busy thread being scheduled?". This answers a
different question that looks the same from inside a test: "is the host moving
pages to and from disk fast enough to stop the guest for tens of seconds?".
Both produce the same symptom — an arbitrary test trips the 60s budget in
`app/dart_test.yaml` — and a CPU probe cannot see this one at all.

**Why a CPU probe is blind to it.** `host_cpu_share.py` burns a tight integer
loop with no allocation and no syscalls. Its working set is a few pages that
stay resident, so it never takes a page fault no matter how hard the rest of
the machine is thrashing. It reports the share it was granted, honestly, and
that share can be SANE in the same window a `VBoxHeadless` faulting guest RAM
back off disk is frozen. The same blindness is why the guest read 96% of a core
with zero steal while it was visibly stalling: steal counts core contention,
and here the vCPU is waiting on the *host's* disk, which no guest counter and
no spin loop can see.

**The measurement behind the thresholds** (fleet Mac, 16 GB, 2026-09-13, LOO-49):
the host was committed to 17.37 GB resident before the OS — VirtualBox 6.53 GB,
21 agent processes 5.78 GB, 48 ruby/rspec 2.62 GB, 65 Chrome 1.59 GB — so it
swapped continuously. Over a 30 s window: 323,432 pages in and 406,817 pages out,
about **100 MB/s sustained**, with macOS growing the swap file from 5,120 to
6,144 MB *during* the measurement. Free memory at the start of that window was
25 MB. A quiet host on the same machine reads **0 pages/s** — this is not a
noisy signal with a judgement call in the middle, it is off or it is a storm.

So VOID is set at 20 MB/s, a fifth of the measured storm and still far above
anything a quiet host produces, and DEGRADED at 2 MB/s, which is "the host has
started trading memory for disk at all". Sustained swapping on a box this
over-committed does not stay mild for long, so the degraded band is deliberately
narrow rather than a comfortable middle to run in.

    python3 tools/host_memory_pressure.py            # 10s sample, prints a verdict
    python3 tools/host_memory_pressure.py --seconds 30
    python3 tools/host_memory_pressure.py --quiet    # exit code only

Exit codes match `host_cpu_share.py` so the two gate identically: 0 sane,
1 degraded, 2 void. Exit 6 means the measurement could not be taken at all —
this reads `vm_stat`, so it is macOS-only, and a host without it gets an honest
"cannot measure" rather than a fabricated all-clear.

Note `vm_stat 5 4` interval mode prints nothing on this macOS; two snapshots
subtracted is the way that works.
"""

import argparse
import re
import subprocess
import sys
import time

# Combined swapin+swapout traffic, in MB/s. See the module docstring for the
# storm and the quiet baseline these sit between.
SWAP_MB_PER_SECOND_DEGRADED = 2.0
SWAP_MB_PER_SECOND_VOID = 20.0

EXIT_SANE = 0
EXIT_DEGRADED = 1
EXIT_VOID = 2
EXIT_CANNOT_MEASURE = 6

DEFAULT_PAGE_SIZE_BYTES = 4096


class CannotMeasure(RuntimeError):
    """`vm_stat` is missing or unreadable — not a verdict about the host."""


def read_vm_stat():
    """Return `vm_stat`'s raw output, or raise CannotMeasure."""
    try:
        completed = subprocess.run(
            ["vm_stat"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
    except OSError as error:
        raise CannotMeasure("could not run vm_stat: {}".format(error))
    if completed.returncode != 0:
        raise CannotMeasure(
            "vm_stat exited {}: {}".format(
                completed.returncode, (completed.stdout or "").strip() or "<no output>"
            )
        )
    return completed.stdout or ""


def parse_vm_stat(text):
    """Pull the page size and the swap counters out of `vm_stat` output.

    Returns (page_size_bytes, {"Swapins": int, "Swapouts": int}). The counters
    are cumulative since boot, so a rate needs two of these subtracted.
    """
    page_size_match = re.search(r"page size of (\d+) bytes", text)
    page_size_bytes = (
        int(page_size_match.group(1)) if page_size_match else DEFAULT_PAGE_SIZE_BYTES
    )

    counters = {}
    for name in ("Swapins", "Swapouts"):
        match = re.search(r"^{}:\s+(\d+)".format(name), text, re.MULTILINE)
        if match is None:
            raise CannotMeasure(
                "vm_stat output has no {} counter — not a macOS vm_stat?".format(name)
            )
        counters[name] = int(match.group(1))
    return page_size_bytes, counters


def swap_megabytes_per_second(before_text, after_text, elapsed_seconds):
    """Combined swapin+swapout traffic between two `vm_stat` snapshots, in MB/s.

    Both directions count. A swapin is the guest's RAM being dragged back off
    disk, which is the stall itself; a swapout is the host deciding it has to
    evict, which is what produces the next swapin. Counting only one of them
    would read a storm at half strength.
    """
    page_size_bytes, before = parse_vm_stat(before_text)
    _, after = parse_vm_stat(after_text)

    # Cumulative counters can only go up; if they went down the machine
    # rebooted or the counter wrapped, and the window is not measurable.
    pages = 0
    for name in ("Swapins", "Swapouts"):
        delta = after[name] - before[name]
        if delta < 0:
            raise CannotMeasure(
                "{} counter went backwards ({} -> {}) — counter wrapped or the "
                "host rebooted mid-sample".format(name, before[name], after[name])
            )
        pages += delta

    if elapsed_seconds <= 0:
        raise CannotMeasure("sample window was {}s".format(elapsed_seconds))
    return (pages * page_size_bytes) / (1024.0 * 1024.0) / elapsed_seconds


def verdict_for(megabytes_per_second):
    """Map swap traffic onto (exit_code, label, what it means for a red run)."""
    if megabytes_per_second >= SWAP_MB_PER_SECOND_VOID:
        return (
            EXIT_VOID,
            "VOID",
            "Do not read a red run from this window. The host is paging hard "
            "enough to stop the guest for tens of seconds at a time, and the "
            "budget fires on whichever test happens to be open.",
        )
    if megabytes_per_second >= SWAP_MB_PER_SECOND_DEGRADED:
        return (
            EXIT_DEGRADED,
            "DEGRADED",
            "Treat a red run as unproven. The host has started trading memory "
            "for disk, and on this machine that rarely stays mild.",
        )
    return (
        EXIT_SANE,
        "SANE",
        "The host is not paging. A timeout from this window is about the code.",
    )


def read_swap_usage():
    """`sysctl vm.swapusage` as a one-line string, or None. Context, not verdict."""
    try:
        completed = subprocess.run(
            ["sysctl", "-n", "vm.swapusage"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    return (completed.stdout or "").strip() or None


def measure_swap_rate(duration_seconds):
    """Sleep across a window and return the swap traffic over it, in MB/s.

    Unlike the CPU probe this one must *not* be busy: the thing being measured
    is the rest of the machine, and burning a core to watch it would add to the
    contention it is trying to read.
    """
    before_text = read_vm_stat()
    wall_start = time.monotonic()
    time.sleep(duration_seconds)
    elapsed_seconds = time.monotonic() - wall_start
    after_text = read_vm_stat()
    return swap_megabytes_per_second(before_text, after_text, elapsed_seconds), elapsed_seconds


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--seconds",
        type=float,
        default=10.0,
        help="wall-clock length of the sample (default: 10)",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="print nothing; communicate through the exit code alone",
    )
    args = parser.parse_args(argv)

    try:
        megabytes_per_second, elapsed_seconds = measure_swap_rate(args.seconds)
    except CannotMeasure as error:
        if not args.quiet:
            print("cannot measure host paging: {}".format(error), file=sys.stderr)
        return EXIT_CANNOT_MEASURE

    exit_code, label, guidance = verdict_for(megabytes_per_second)

    if not args.quiet:
        swap_usage = read_swap_usage()
        print(
            "swap traffic {:.1f} MB/s over {:.1f}s wall{}".format(
                megabytes_per_second,
                elapsed_seconds,
                " (swapfile: {})".format(swap_usage) if swap_usage else "",
            )
        )
        print("{}: {}".format(label, guidance))

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
