#!/usr/bin/env python3
"""Journey tests for `tools/builder_run.py`.

The outermost tier that executes here is the wrapper itself, run as a real
process: a real `flock` on a real file, a real probe subprocess, a real payload
subprocess. Nothing is mocked. What varies between tests is the *probe's*
answer, which is supplied by a small real script that exits down a scripted
sequence of codes — the same contract `tools/host_cpu_share.py` offers
(0 sane, 1 degraded, 2 void).

    python3 -m unittest discover -s tools/tests -t .
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WRAPPER = REPO_ROOT / "tools" / "builder_run.py"

# Mirrors builder_run.py's exit codes. Duplicated deliberately: a test that
# imported them could not catch a renumbering, which is the thing callers see.
EXIT_PASS = 0
EXIT_FAILED = 1
EXIT_UNPROVEN = 3
EXIT_NO_SANE_WINDOW = 4
EXIT_LOCK_BUSY = 5
EXIT_NOT_CONFIGURED = 7


def load_wrapper_module():
    """Import builder_run.py by path — `tools/` is not a package."""
    spec = importlib.util.spec_from_file_location("builder_run", WRAPPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

# A probe script whose verdict walks a scripted sequence, one step per call,
# holding the last value once the sequence runs out. It ignores the flags the
# wrapper passes (`--seconds`, `--quiet`) exactly as far as it has to.
FAKE_PROBE = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import pathlib, sys

    here = pathlib.Path(__file__).resolve()
    codes = here.with_suffix(".codes").read_text().split()
    calls_path = here.with_suffix(".calls")
    calls = int(calls_path.read_text()) if calls_path.exists() else 0
    calls_path.write_text(str(calls + 1))
    code = int(codes[min(calls, len(codes) - 1)])
    print("fake probe call {} -> {}".format(calls, code))
    sys.exit(code)
    """
)

# A payload that records when it started and finished, so an overlap between
# two runs is visible in the file rather than inferred from timing.
PAYLOAD = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import os, pathlib, sys, time

    log = pathlib.Path(sys.argv[1])
    tag = sys.argv[2]
    exit_code = int(sys.argv[3])
    hold_seconds = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0

    with log.open("a") as handle:
        handle.write("{} start {:.4f}\\n".format(tag, time.monotonic()))
    time.sleep(hold_seconds)
    with log.open("a") as handle:
        handle.write("{} end {:.4f}\\n".format(tag, time.monotonic()))
    sys.exit(exit_code)
    """
)


class BuilderRunJourney(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(
            tempfile.mkdtemp(prefix="builder_run_", dir=os.environ.get("TMPDIR") or None)
        )
        self.lock_path = self.scratch / "builder_run.lock"
        self.payload_path = self.scratch / "payload.py"
        self.payload_path.write_text(PAYLOAD)
        self.payload_log = self.scratch / "payload.log"
        # Every run is pointed at a config under this test's scratch, absent
        # unless the test writes one. Without this a developer's real
        # ~/.jeeves/builder.json would leak into the run and the suite would
        # pass or fail by accident of whose machine it is on.
        self.config_path = self.scratch / "builder.json"

    def write_probe(self, name, codes):
        """Install a probe that answers `codes`, one per call. Returns its path."""
        probe_path = self.scratch / "{}.py".format(name)
        probe_path.write_text(FAKE_PROBE)
        probe_path.with_suffix(".codes").write_text(" ".join(str(code) for code in codes))
        return probe_path

    def probe_calls(self, probe_path):
        calls_path = probe_path.with_suffix(".calls")
        return int(calls_path.read_text()) if calls_path.exists() else 0

    def run_wrapper(self, probes, payload_args, extra_args=()):
        """Drive the wrapper against one probe, or several that must all be SANE."""
        probe_paths = [probes] if isinstance(probes, Path) else list(probes)
        probe_args = []
        for probe_path in probe_paths:
            probe_args += ["--probe", str(probe_path)]
        command = [
            sys.executable,
            str(WRAPPER),
            "--config",
            str(self.config_path),
            *probe_args,
            "--lock-path",
            str(self.lock_path),
            "--probe-seconds",
            "0.01",
            "--poll-interval-seconds",
            "0.05",
            "--deadline-seconds",
            "10",
            *extra_args,
            "--",
            sys.executable,
            str(self.payload_path),
            str(self.payload_log),
            *[str(arg) for arg in payload_args],
        ]
        return subprocess.run(command, capture_output=True, text=True, timeout=120)

    def payload_events(self):
        if not self.payload_log.exists():
            return []
        return [line.split() for line in self.payload_log.read_text().splitlines()]

    # --- the gate ----------------------------------------------------------

    def test_a_void_window_waits_rather_than_running(self):
        """VOID, VOID, then SANE: the payload starts only after the window clears."""
        probe = self.write_probe("clears", [2, 2, 0, 0])

        result = self.run_wrapper(probe, ["only", 0])

        self.assertEqual(result.returncode, EXIT_PASS, result.stderr)
        self.assertIn("VOID", result.stderr)
        self.assertIn("waiting", result.stderr.lower())
        # Three gate calls to clear the window, one re-check after the run.
        self.assertEqual(self.probe_calls(probe), 4)
        self.assertEqual([event[1] for event in self.payload_events()], ["start", "end"])

    def test_a_window_that_never_clears_reports_no_sane_window(self):
        """On expiry the run exits with no test verdict, and never starts the payload."""
        probe = self.write_probe("never_clears", [2])

        result = self.run_wrapper(
            probe, ["never", 0], extra_args=["--deadline-seconds", "0.4"]
        )

        self.assertEqual(result.returncode, EXIT_NO_SANE_WINDOW, result.stderr)
        self.assertIn("no sane window", result.stderr.lower())
        self.assertEqual(self.payload_events(), [])

    def test_a_degraded_window_is_not_sane_enough_to_start(self):
        """The gate waits for SANE, not merely for not-VOID."""
        probe = self.write_probe("degraded", [1])

        result = self.run_wrapper(
            probe, ["degraded", 0], extra_args=["--deadline-seconds", "0.4"]
        )

        self.assertEqual(result.returncode, EXIT_NO_SANE_WINDOW, result.stderr)
        self.assertIn("DEGRADED", result.stderr)
        self.assertEqual(self.payload_events(), [])

    # --- gating on more than one resource ----------------------------------

    def test_one_void_probe_holds_the_run_even_when_the_other_is_sane(self):
        """The regression this gate exists for: CPU SANE is not an all-clear.

        `host_cpu_share.py` spins over a resident working set, so it never page
        faults and reads SANE straight through a swap storm — the condition
        that actually stalls the guest for tens of seconds. If one probe could
        vote down another, that window would open.
        """
        cpu = self.write_probe("cpu_sane", [0])
        memory = self.write_probe("memory_void", [2])

        result = self.run_wrapper(
            [cpu, memory], ["starved", 0], extra_args=["--deadline-seconds", "0.4"]
        )

        self.assertEqual(result.returncode, EXIT_NO_SANE_WINDOW, result.stderr)
        self.assertIn("memory_void.py VOID", result.stderr)
        self.assertEqual(self.payload_events(), [])

    def test_a_non_sane_probe_short_circuits_the_probes_after_it(self):
        """Nothing is left to learn about a window already known to be unusable."""
        cpu = self.write_probe("cpu_void", [2])
        memory = self.write_probe("memory_unreached", [0])

        result = self.run_wrapper(
            [cpu, memory], ["unreached", 0], extra_args=["--deadline-seconds", "0.4"]
        )

        self.assertEqual(result.returncode, EXIT_NO_SANE_WINDOW, result.stderr)
        self.assertGreaterEqual(self.probe_calls(cpu), 1)
        self.assertEqual(self.probe_calls(memory), 0)

    def test_a_run_starts_only_once_every_probe_reports_sane(self):
        cpu = self.write_probe("cpu_clears", [0])
        memory = self.write_probe("memory_clears", [2, 0])

        result = self.run_wrapper([cpu, memory], ["both", 0])

        self.assertEqual(result.returncode, EXIT_PASS, result.stderr)
        self.assertIn("cpu_clears.py SANE, memory_clears.py SANE", result.stderr)
        self.assertEqual([event[1] for event in self.payload_events()], ["start", "end"])

    def test_a_red_is_unproven_when_the_second_probe_degrades_mid_run(self):
        """Worst-of decides: the CPU window held, but the host started paging."""
        cpu = self.write_probe("cpu_held", [0, 0])
        memory = self.write_probe("memory_fell", [0, 1])

        result = self.run_wrapper([cpu, memory], ["red", 1])

        self.assertEqual(result.returncode, EXIT_UNPROVEN, result.stderr)
        self.assertIn("UNPROVEN", result.stderr)
        self.assertIn("memory_fell.py DEGRADED", result.stderr)

    # --- the verdict -------------------------------------------------------

    def test_a_red_run_in_a_window_that_held_is_a_failure(self):
        probe = self.write_probe("held", [0, 0])

        result = self.run_wrapper(probe, ["red", 1])

        self.assertEqual(result.returncode, EXIT_FAILED, result.stderr)
        self.assertIn("FAILED", result.stderr)

    def test_a_red_run_whose_window_degraded_mid_flight_is_unproven(self):
        """Sane at the start, void at the end: the red says nothing about the code."""
        probe = self.write_probe("degrades", [0, 2])

        result = self.run_wrapper(probe, ["unproven", 1])

        self.assertEqual(result.returncode, EXIT_UNPROVEN, result.stderr)
        self.assertIn("UNPROVEN", result.stderr)
        self.assertNotIn("FAILED", result.stderr)

    def test_a_green_run_stays_green_even_if_the_window_degraded(self):
        """Starvation can only invent a timeout, so it cannot forge a pass."""
        probe = self.write_probe("degrades_green", [0, 2])

        result = self.run_wrapper(probe, ["green", 0])

        self.assertEqual(result.returncode, EXIT_PASS, result.stderr)
        self.assertIn("PASS", result.stderr)

    # --- serialisation -----------------------------------------------------

    def test_two_runs_started_at_once_do_not_overlap(self):
        first_probe = self.write_probe("first", [0, 0])
        second_probe = self.write_probe("second", [0, 0])
        results = {}

        def start(name, probe, tag, hold_seconds):
            results[name] = self.run_wrapper(probe, [tag, 0, hold_seconds])

        threads = [
            threading.Thread(target=start, args=("first", first_probe, "first", 1.0)),
            threading.Thread(target=start, args=("second", second_probe, "second", 0.1)),
        ]
        threads[0].start()
        time.sleep(0.3)  # let the first run take the lock before the second asks
        threads[1].start()
        for thread in threads:
            thread.join()

        self.assertEqual(results["first"].returncode, EXIT_PASS, results["first"].stderr)
        self.assertEqual(results["second"].returncode, EXIT_PASS, results["second"].stderr)
        self.assertIn("waiting for the builder lock", results["second"].stderr)

        events = self.payload_events()
        self.assertEqual(
            [event[0] for event in events],
            ["first", "first", "second", "second"],
            "runs overlapped: {}".format(events),
        )

    def test_a_run_that_cannot_get_the_lock_in_time_says_so(self):
        holder_probe = self.write_probe("holder", [0, 0])
        waiter_probe = self.write_probe("waiter", [0, 0])
        holder = {}

        def start_holder():
            holder["result"] = self.run_wrapper(holder_probe, ["holder", 0, 2.0])

        thread = threading.Thread(target=start_holder)
        thread.start()
        time.sleep(0.3)
        waiter = self.run_wrapper(
            waiter_probe, ["waiter", 0], extra_args=["--deadline-seconds", "0.4"]
        )
        thread.join()

        self.assertEqual(waiter.returncode, EXIT_LOCK_BUSY, waiter.stderr)
        self.assertIn("another builder run", waiter.stderr.lower())
        # The waiter gave up before probing: the gate is taken behind the lock,
        # so a queued run does not burn CPU measuring a window it cannot use.
        self.assertEqual(self.probe_calls(waiter_probe), 0)
        self.assertEqual([event[0] for event in self.payload_events()], ["holder", "holder"])


class MachineConfigStaysOffTheRepo(unittest.TestCase):
    """The repo carries the mechanism; the machine carries which host it is.

    This repository is public, so the builder's account, port-forward, key and
    checkout path must not be in it. The invariant that keeps them out is that
    there is no fallback: with nothing configured the wrapper has no host to
    guess at and says so, rather than reaching for a default someone would
    later have to fill in here.
    """

    def setUp(self):
        self.builder_run = load_wrapper_module()
        self.scratch = Path(
            tempfile.mkdtemp(prefix="builder_cfg_", dir=os.environ.get("TMPDIR") or None)
        )
        self.config_path = self.scratch / "builder.json"

    def args_for(self, command=(), remote_command=None):
        """The wrapper's parsed-args surface, as `build_command` reads it."""

        class Args:
            pass

        args = Args()
        args.command = list(command)
        args.remote_command = remote_command
        return args

    def test_no_config_means_no_host_to_reach_rather_than_a_default(self):
        with self.assertRaises(self.builder_run.NotConfigured) as caught:
            self.builder_run.build_command(self.args_for(), {}, self.config_path)

        message = str(caught.exception)
        self.assertIn(str(self.config_path), message)
        self.assertIn("does not exist", message)
        # It tells you the shape to write, in placeholders only — a filled-in
        # example here would be the very thing this test exists to keep out.
        self.assertIn("<user>@<host>", message)

    def test_a_config_naming_no_host_is_still_not_configured(self):
        self.config_path.write_text(json.dumps({"remote_command": "true"}))
        config = self.builder_run.load_config(self.config_path)

        with self.assertRaises(self.builder_run.NotConfigured):
            self.builder_run.build_command(self.args_for(), config, self.config_path)

    def test_the_ssh_command_is_assembled_from_the_machines_config(self):
        self.config_path.write_text(
            json.dumps(
                {
                    "ssh": {
                        "host": "someone@10.0.0.9",
                        "port": "2201",
                        "identity_file": "/keys/builder",
                    },
                    "remote_command": "cd ~/checkout/app && flutter test",
                }
            )
        )
        config = self.builder_run.load_config(self.config_path)

        command = self.builder_run.build_command(self.args_for(), config, self.config_path)

        self.assertEqual(
            command,
            [
                "ssh",
                "-i",
                "/keys/builder",
                "-p",
                "2201",
                "someone@10.0.0.9",
                "cd ~/checkout/app && flutter test",
            ],
        )

    def test_an_explicit_command_needs_no_config_at_all(self):
        """How the suite and CI drive the wrapper: gating something local."""
        command = self.builder_run.build_command(
            self.args_for(command=["echo", "hello"]), {}, self.config_path
        )

        self.assertEqual(command, ["echo", "hello"])

    def test_an_unreadable_config_is_an_error_not_a_silent_fallback(self):
        """A machine that meant to configure itself and typo'd should hear about it."""
        self.config_path.write_text("{ not json")

        with self.assertRaises(self.builder_run.NotConfigured) as caught:
            self.builder_run.load_config(self.config_path)

        self.assertIn("not valid JSON", str(caught.exception))

    def test_probe_calibration_can_live_on_the_machine(self):
        """Thresholds tuned to one host belong in its config, not in the repo."""
        config = {
            "probes": [
                "tools/host_cpu_share.py",
                ["tools/host_memory_pressure.py", "--void-mb-per-second", "30"],
            ]
        }

        probes = self.builder_run.resolve_probes(None, config)

        self.assertEqual(
            [Path(probe[0]).name for probe in probes],
            ["host_cpu_share.py", "host_memory_pressure.py"],
        )
        # Relative paths resolve against the repo, so a config can name a probe
        # without knowing where the checkout sits on that machine.
        self.assertTrue(Path(probes[0][0]).is_absolute())
        self.assertEqual(probes[1][1:], ["--void-mb-per-second", "30"])

    def test_a_probe_flag_still_wins_over_the_machines_probes(self):
        probes = self.builder_run.resolve_probes(
            ["/tmp/mine.py"], {"probes": ["tools/host_cpu_share.py"]}
        )

        self.assertEqual(probes, [["/tmp/mine.py"]])

    def test_an_unconfigured_run_exits_seven_without_probing(self):
        """End to end: nothing is measured and nothing is run."""
        result = subprocess.run(
            [
                sys.executable,
                str(WRAPPER),
                "--config",
                str(self.scratch / "absent.json"),
                "--deadline-seconds",
                "0.4",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, EXIT_NOT_CONFIGURED, result.stderr)
        self.assertIn("not configured", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
