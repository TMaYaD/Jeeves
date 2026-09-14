#!/usr/bin/env python3
"""Run a test on the x86_64 builder only in a window the host can schedule.

This is the route a builder run goes through; do not `ssh` in and call
`flutter test` by hand. It does three things around the run:

  serialise  Take an exclusive host-side lock, so two builder runs queue
             instead of halving each other's share of an already-short host.
  gate       Poll the host probes until *every* one reports SANE, with a
             deadline. Past the deadline the run reports "no sane window" and
             exits with no test verdict — a run that never started is better
             signal than a red one nobody can read.
  re-check   Measure again when the run finishes. A red from a window that
             degraded mid-flight is reported UNPROVEN, not FAILED.

**The probes run on the host, never in the guest, and that is the whole
design.** Measured in one window on 2026-09-13 with the host's 1-minute load
average near 100: two busy threads on the guest's 2 vCPUs were granted 96% and
98% of a core — SANE — while the CPU probe on the host was granted 12% —
VOID. VirtualBox's long-lived vCPU threads hold a share that a freshly spawned
host process does not, so a guest-side reading is a false all-clear from a
window that will still eat the 60s budget in `app/dart_test.yaml`. See LOO-49
and `docs/TESTING.md` § Frontend (Flutter).

**Two resources are gated, not one, because the host starves the guest two
different ways and each is invisible to the other's probe.**

  `host_cpu_share.py`       the host is not scheduling a fresh process
  `host_memory_pressure.py` the host is paging, so the guest is waiting on disk

A spin loop with a resident working set never faults, so the CPU probe reads a
swap storm as SANE; and the 2026-09-13 measurement of a host at load 438 with
*zero* swapouts shows the converse, so neither probe subsumes the other. Both
must be SANE for a run to start, and the worst verdict of the two is the one
the run is judged against. Adding a probe is adding a `--probe` — the contract
is only the exit code (0 sane, 1 degraded, 2 void).

**The lock is taken before the gate**, in that order for two reasons: a queued
run should not burn a core measuring a window it cannot use yet (the
measurement is itself contention), and the window a run starts in should have
been measured after the run ahead of it finished, not before it.

It gates and serialises; it does not ship code. The default command runs
whatever already sits in the guest's `~/jeeves`, so put your branch there
first — the wrapper has no opinion about what it is testing.

    python3 tools/builder_run.py                     # flutter test in the guest
    python3 tools/builder_run.py --remote-command 'cd ~/jeeves/app && flutter analyze'
    python3 tools/builder_run.py -- <argv...>        # gate an arbitrary command

Exit codes are the contract, and they separate "the code is wrong" from "the
host was not usable":

    0  PASS            the command succeeded
    1  FAILED          the command failed in a window that held: read the red
    3  UNPROVEN        the command failed, but the window degraded: re-run
    4  NO SANE WINDOW  the deadline passed without one; no test verdict
    5  LOCK BUSY       another builder run held the lock past the deadline
    6  PROBE ERROR     a probe could not be run at all
"""

import argparse
import errno
import fcntl
import os
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
# Both are gated, and the order is the order they run in: the CPU probe burns a
# core for its sample, the memory probe deliberately sleeps through its own, so
# a host that fails the cheap-to-fail check does not pay for the quiet one.
DEFAULT_PROBES = (
    REPO_ROOT / "tools" / "host_cpu_share.py",
    REPO_ROOT / "tools" / "host_memory_pressure.py",
)

# How to reach the guest. The runbook these come from — start/stop, the NAT
# port-forward that is the only route in, and why the toolchain is on PATH for
# a non-interactive `ssh host '<cmd>'` — is infra/README.md § The
# `jeeves-builder` Android build VM.
BUILDER_SSH_HOST = "paperclipai@127.0.0.1"
BUILDER_SSH_PORT = "2222"
BUILDER_SSH_KEY = "~/.ssh/id_ed25519"
DEFAULT_REMOTE_COMMAND = "cd ~/jeeves/app && flutter test"

# One lock for the whole host, outside any worktree, because the runs it
# serialises are in different checkouts of the same repo.
DEFAULT_LOCK_PATH = "~/.jeeves/builder_run.lock"

# `host_cpu_share.py`'s exit codes, which this file only reads.
PROBE_SANE = 0
PROBE_DEGRADED = 1
PROBE_VOID = 2
PROBE_LABELS = {PROBE_SANE: "SANE", PROBE_DEGRADED: "DEGRADED", PROBE_VOID: "VOID"}

EXIT_PASS = 0
EXIT_FAILED = 1
EXIT_UNPROVEN = 3
EXIT_NO_SANE_WINDOW = 4
EXIT_LOCK_BUSY = 5
EXIT_PROBE_ERROR = 6


class ProbeError(RuntimeError):
    """The probe could not be run — a broken harness, not a starved host."""


def say(message):
    """Narrate to stderr, so the payload owns stdout unmolested."""
    print("[builder-run] {}".format(message), file=sys.stderr, flush=True)


def run_probe(probe_path, probe_seconds):
    """Sample the host's CPU share once. Returns the probe's exit code."""
    try:
        completed = subprocess.run(
            [sys.executable, str(probe_path), "--seconds", str(probe_seconds)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except OSError as error:
        raise ProbeError("could not run probe {}: {}".format(probe_path, error))

    output = (completed.stdout or "").strip()
    if completed.returncode not in PROBE_LABELS:
        raise ProbeError(
            "probe {} exited {} (expected 0, 1 or 2): {}".format(
                probe_path, completed.returncode, output or "<no output>"
            )
        )
    if output:
        for line in output.splitlines():
            say("probe: {}".format(line))
    return completed.returncode


def run_probes(probe_paths, probe_seconds):
    """Sample every probe once. Returns (worst verdict, [(name, verdict), ...]).

    Worst wins: the host is only usable if nothing it needs is short, so a
    SANE from one resource cannot vote down a VOID from another. Probes run in
    sequence and the first non-SANE one short-circuits the rest — there is
    nothing left to learn about a window already known to be unusable, and the
    sampling itself costs wall clock the deadline is paying for.
    """
    results = []
    for probe_path in probe_paths:
        verdict = run_probe(probe_path, probe_seconds)
        results.append((probe_path.name, verdict))
        if verdict != PROBE_SANE:
            return verdict, results
    return PROBE_SANE, results


def describe(results):
    """`host_cpu_share.py SANE, host_memory_pressure.py VOID` — for the narration."""
    return ", ".join(
        "{} {}".format(name, PROBE_LABELS[verdict]) for name, verdict in results
    )


def acquire_lock(lock_path, deadline_monotonic, poll_interval_seconds):
    """Take the exclusive builder lock, waiting until the deadline.

    Returns the held file object, or None if the deadline passed first. The
    lock is `flock`-based so it dies with the process: a run killed mid-flight
    releases it, where a lock file checked for existence would strand every
    later run behind a corpse.
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_path.open("a+")
    announced_wait = False
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                handle.close()
                raise
        if not announced_wait:
            say("waiting for the builder lock at {} — another run holds it".format(lock_path))
            announced_wait = True
        if time.monotonic() >= deadline_monotonic:
            handle.close()
            return None
        time.sleep(min(poll_interval_seconds, max(0.0, deadline_monotonic - time.monotonic())))


def wait_for_sane_window(
    probe_paths, probe_seconds, deadline_monotonic, poll_interval_seconds
):
    """Poll until every host probe reports SANE. Returns True, or False on expiry."""
    attempt = 0
    while True:
        attempt += 1
        verdict, results = run_probes(probe_paths, probe_seconds)
        if verdict == PROBE_SANE:
            say(
                "host window is SANE after {} round(s) ({}) — starting the run".format(
                    attempt, describe(results)
                )
            )
            return True
        remaining_seconds = deadline_monotonic - time.monotonic()
        if remaining_seconds <= 0:
            say(
                "host window is still {} after {} round(s) ({})".format(
                    PROBE_LABELS[verdict], attempt, describe(results)
                )
            )
            return False
        say(
            "host window is {} ({}) — waiting {:.0f}s, {:.0f}s left on the "
            "deadline".format(
                PROBE_LABELS[verdict],
                describe(results),
                poll_interval_seconds,
                remaining_seconds,
            )
        )
        time.sleep(min(poll_interval_seconds, remaining_seconds))


def build_command(args):
    """The argv to run: an explicit one, or `--remote-command` over ssh."""
    if args.command:
        return args.command
    return [
        "ssh",
        "-i",
        os.path.expanduser(BUILDER_SSH_KEY),
        "-p",
        BUILDER_SSH_PORT,
        BUILDER_SSH_HOST,
        args.remote_command,
    ]


def report(command_exit_code, window_after, elapsed_seconds, results_after=()):
    """Turn (what the command said, what the window said afterwards) into a verdict.

    A red is only readable if the window held: starvation invents timeouts, and
    a timeout is indistinguishable from a real one from inside the suite. A
    green needs no such caveat — a starved host can lose a run, it cannot forge
    a pass — so a green from a degraded window is still a green, noted.
    """
    label = PROBE_LABELS[window_after]
    detail = " ({})".format(describe(results_after)) if results_after else ""
    if command_exit_code == 0:
        if window_after != PROBE_SANE:
            say(
                "the window fell to {}{} during the run, but the command passed — "
                "starvation can only invent a failure, never a pass".format(
                    label, detail
                )
            )
        say("PASS in {:.0f}s — the command succeeded".format(elapsed_seconds))
        return EXIT_PASS

    if window_after == PROBE_SANE:
        say(
            "FAILED in {:.0f}s — the command exited {} and the host window held "
            "at both ends{}, so the red is about the code".format(
                elapsed_seconds, command_exit_code, detail
            )
        )
        return EXIT_FAILED

    say(
        "UNPROVEN in {:.0f}s — the command exited {}, but the host window fell to "
        "{}{} during the run. Do not read this red as a test failure; re-run.".format(
            elapsed_seconds, command_exit_code, label, detail
        )
    )
    return EXIT_UNPROVEN


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog="Exit codes: 0 pass, 1 failed, 3 unproven, 4 no sane window, "
        "5 lock busy, 6 probe error.",
    )
    parser.add_argument(
        "--probe",
        action="append",
        dest="probes",
        metavar="PATH",
        help="host probe to gate on; repeat to gate on several, and every one "
        "must report SANE. Any script exiting 0 sane / 1 degraded / 2 void "
        "will do. They run on this machine — the host — never in the guest. "
        "(default: {})".format(
            ", ".join("tools/{}".format(probe.name) for probe in DEFAULT_PROBES)
        ),
    )
    parser.add_argument(
        "--probe-seconds",
        type=float,
        default=10.0,
        help="wall-clock length of each probe sample (default: 10)",
    )
    parser.add_argument(
        "--poll-interval-seconds",
        type=float,
        default=20.0,
        help="gap between probes while waiting for a sane window (default: 20)",
    )
    parser.add_argument(
        "--deadline-seconds",
        type=float,
        default=1800.0,
        help="how long to wait for the lock and a sane window before giving up "
        "(default: 1800)",
    )
    parser.add_argument(
        "--lock-path",
        default=DEFAULT_LOCK_PATH,
        help="exclusive lock serialising builder runs (default: {})".format(
            DEFAULT_LOCK_PATH
        ),
    )
    parser.add_argument(
        "--remote-command",
        default=DEFAULT_REMOTE_COMMAND,
        help="shell command to run in the guest when no command is given "
        "(default: {!r})".format(DEFAULT_REMOTE_COMMAND),
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="run this argv instead of reaching the guest over ssh; "
        "pass it after `--`",
    )
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]

    probe_paths = [
        Path(probe).expanduser() for probe in (args.probes or DEFAULT_PROBES)
    ]
    lock_path = Path(args.lock_path).expanduser()
    deadline_monotonic = time.monotonic() + args.deadline_seconds

    lock_handle = acquire_lock(lock_path, deadline_monotonic, args.poll_interval_seconds)
    if lock_handle is None:
        say(
            "giving up: another builder run held the lock for the whole "
            "{:.0f}s deadline. No test verdict.".format(args.deadline_seconds)
        )
        return EXIT_LOCK_BUSY

    try:
        try:
            if not wait_for_sane_window(
                probe_paths,
                args.probe_seconds,
                deadline_monotonic,
                args.poll_interval_seconds,
            ):
                say(
                    "giving up: no sane window inside the {:.0f}s deadline. The host "
                    "cannot schedule this run, so it did not start — there is no "
                    "test verdict, and this is not a red.".format(args.deadline_seconds)
                )
                return EXIT_NO_SANE_WINDOW

            command = build_command(args)
            say("running: {}".format(" ".join(command)))
            started_monotonic = time.monotonic()
            command_exit_code = subprocess.run(command).returncode
            elapsed_seconds = time.monotonic() - started_monotonic

            say("re-checking the host window the run just finished in")
            window_after, results_after = run_probes(probe_paths, args.probe_seconds)
            return report(
                command_exit_code, window_after, elapsed_seconds, results_after
            )
        except ProbeError as error:
            say("probe error: {}".format(error))
            return EXIT_PROBE_ERROR
    finally:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
        lock_handle.close()


if __name__ == "__main__":
    sys.exit(main())
