#!/usr/bin/env python3
"""Measure the share of a CPU core this machine actually grants a busy thread.

A `package:test` timeout is charged in wall clock, but a test only makes
progress while its thread is scheduled. When the box is oversubscribed those
two diverge, and an arbitrary test — not the slow one, not the one near its
budget — trips the 60s budget in `app/dart_test.yaml`. That red says nothing
about the code, and nothing inside the suite can tell it apart from a real
failure. This script is the outside measurement that can.

Run it on the **host**. Inside a guest it reports the host's contention only by
accident: measured in one window on the x86_64 builder, two busy threads on the
guest's 2 vCPUs were granted 96% and 98% of a core — SANE — while this same
script on the host was granted 12% — VOID. VirtualBox's vCPU threads hold their
share where a fresh host process does not, so a guest-side reading is a false
all-clear. Run it in the guest only to rule the guest's *own* load in or out.

    python3 tools/host_cpu_share.py            # 10s sample, prints a verdict
    python3 tools/host_cpu_share.py --seconds 30
    python3 tools/host_cpu_share.py --quiet    # exit code only

Exit codes let a run gate on the answer: 0 sane, 1 degraded, 2 void.
"""

import argparse
import resource
import sys
import time

# A thread that is never descheduled gets cpu_seconds == wall_seconds, i.e. a
# share of 1.0. Below HALF, wall-clock dilation exceeds 2x and the 60s budget
# is effectively under 30s, which is inside the range real tests occupy on the
# slowest host the suite runs on (see app/dart_test.yaml). Below QUARTER the
# dilation exceeds 4x and any red is uninterpretable.
SHARE_DEGRADED = 0.50
SHARE_VOID = 0.25

EXIT_SANE = 0
EXIT_DEGRADED = 1
EXIT_VOID = 2


def measure_cpu_share(duration_seconds):
    """Burn CPU for `duration_seconds` of wall time; return what we were granted.

    Returns (share, wall_seconds, cpu_seconds, involuntary_context_switches).
    `share` is cpu/wall: 1.0 means the thread owned a core outright, 0.1 means
    it was descheduled for nine tenths of the interval.
    """
    usage_before = resource.getrusage(resource.RUSAGE_SELF)
    wall_start = time.monotonic()

    # Plain integer work, no allocation and no syscalls, so the loop yields the
    # CPU only when the scheduler takes it away. The inner count keeps the
    # clock read off the hot path without overshooting the sample window.
    counter = 0
    while time.monotonic() - wall_start < duration_seconds:
        for _ in range(20000):
            counter += 1

    usage_after = resource.getrusage(resource.RUSAGE_SELF)
    wall_seconds = time.monotonic() - wall_start
    cpu_seconds = (usage_after.ru_utime - usage_before.ru_utime) + (
        usage_after.ru_stime - usage_before.ru_stime
    )
    involuntary_context_switches = usage_after.ru_nivcsw - usage_before.ru_nivcsw
    return cpu_seconds / wall_seconds, wall_seconds, cpu_seconds, involuntary_context_switches


def verdict_for(share):
    """Map a granted share onto (exit_code, label, what it means for a red run)."""
    if share < SHARE_VOID:
        return (
            EXIT_VOID,
            "VOID",
            "Do not read a red run from this window. Wall clock is running "
            "more than 4x ahead of progress, so the budget fires on whichever "
            "test happens to be open.",
        )
    if share < SHARE_DEGRADED:
        return (
            EXIT_DEGRADED,
            "DEGRADED",
            "Treat a red run as unproven. Wall clock is running more than 2x "
            "ahead of progress; re-run before believing a timeout.",
        )
    return (
        EXIT_SANE,
        "SANE",
        "A timeout from this window is about the code.",
    )


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

    share, wall_seconds, cpu_seconds, involuntary_context_switches = measure_cpu_share(
        args.seconds
    )
    exit_code, label, guidance = verdict_for(share)

    if not args.quiet:
        print(
            "cpu share {:.0%} of one core "
            "({:.2f}s granted over {:.2f}s wall, {} involuntary switches)".format(
                share, cpu_seconds, wall_seconds, involuntary_context_switches
            )
        )
        print("{}: {}".format(label, guidance))

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
