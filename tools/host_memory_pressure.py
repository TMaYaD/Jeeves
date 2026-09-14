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

**Why the thresholds sit where they do** (measured during a real storm on the
builder host, 2026-09-13, LOO-49). A host over-committed enough to swap does not
produce a gentle signal: sustained traffic through that window ran more than an
order of magnitude above the VOID line below, while a quiet host on the same
machine reads **zero** pages per second. There is no ambiguous middle to
calibrate — paging here is off, or it is a storm — so VOID sits far enough below
the measured storm to catch it early, DEGRADED at "the host has started trading
memory for disk at all", and the band between them is deliberately narrow rather
than a comfortable middle to run in.

The defaults are a starting point, not a property of any particular machine. A
host that needs different numbers passes them, and keeps them in its own
`builder.json` (see `tools/builder_run.py`) rather than here — the calibration
belongs to the machine, this file is the mechanism.

    python3 tools/host_memory_pressure.py            # 10s sample, prints a verdict
    python3 tools/host_memory_pressure.py --seconds 30
    python3 tools/host_memory_pressure.py --quiet    # exit code only
    python3 tools/host_memory_pressure.py --void-mb-per-second 30

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

# Combined swapin+swapout traffic, in MB/s. Defaults only — see the module
# docstring for the storm and the quiet baseline these sit between, and for why
# a machine that wants different numbers carries them itself.
DEFAULT_SWAP_MB_PER_SECOND_DEGRADED = 2.0
DEFAULT_SWAP_MB_PER_SECOND_VOID = 20.0

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


def verdict_for(
    megabytes_per_second,
    degraded_threshold=DEFAULT_SWAP_MB_PER_SECOND_DEGRADED,
    void_threshold=DEFAULT_SWAP_MB_PER_SECOND_VOID,
):
    """Map swap traffic onto (exit_code, label, what it means for a red run)."""
    if megabytes_per_second >= void_threshold:
        return (
            EXIT_VOID,
            "VOID",
            "Do not read a red run from this window. The host is paging hard "
            "enough to stop the guest for tens of seconds at a time, and the "
            "budget fires on whichever test happens to be open.",
        )
    if megabytes_per_second >= degraded_threshold:
        return (
            EXIT_DEGRADED,
            "DEGRADED",
            "Treat a red run as unproven. The host has started trading memory "
            "for disk, and that rarely stays mild for long.",
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
    parser.add_argument(
        "--degraded-mb-per-second",
        type=float,
        default=DEFAULT_SWAP_MB_PER_SECOND_DEGRADED,
        help="swap traffic at or above which the window is DEGRADED "
        "(default: {})".format(DEFAULT_SWAP_MB_PER_SECOND_DEGRADED),
    )
    parser.add_argument(
        "--void-mb-per-second",
        type=float,
        default=DEFAULT_SWAP_MB_PER_SECOND_VOID,
        help="swap traffic at or above which the window is VOID "
        "(default: {})".format(DEFAULT_SWAP_MB_PER_SECOND_VOID),
    )
    args = parser.parse_args(argv)

    try:
        megabytes_per_second, elapsed_seconds = measure_swap_rate(args.seconds)
    except CannotMeasure as error:
        if not args.quiet:
            print("cannot measure host paging: {}".format(error), file=sys.stderr)
        return EXIT_CANNOT_MEASURE

    exit_code, label, guidance = verdict_for(
        megabytes_per_second,
        args.degraded_mb_per_second,
        args.void_mb_per_second,
    )

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
