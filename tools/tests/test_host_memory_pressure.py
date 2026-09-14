#!/usr/bin/env python3
"""Tests for `tools/host_memory_pressure.py`.

The rate arithmetic and the thresholds are pure, and they are tested against
real `vm_stat` text rather than a stub of it — the two fixtures below are the
shapes this has to read: the fleet Mac quiet, and the fleet Mac mid-storm on
2026-09-13 (the window recorded on LOO-49). CI runs these on Linux, which has
no `vm_stat`, so the arithmetic tests never shell out; the tests that do run
the probe accept its "cannot measure" exit there rather than being pinned to
macOS, because that refusal is itself the contract worth holding.

    python3 -m unittest discover -s tools/tests -t .
"""

import importlib.util
import shutil
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE = REPO_ROOT / "tools" / "host_memory_pressure.py"

# tools/ is not a package, so the module is loaded by path.
_spec = importlib.util.spec_from_file_location("host_memory_pressure", PROBE)
host_memory_pressure = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(host_memory_pressure)

EXIT_SANE = 0
EXIT_DEGRADED = 1
EXIT_VOID = 2
EXIT_CANNOT_MEASURE = 6

# Real `vm_stat` output, trimmed to the lines the probe reads. Counters are
# cumulative since boot; a rate comes from subtracting two of these.
QUIET = textwrap.dedent(
    """\
    Mach Virtual Memory Statistics: (page size of 4096 bytes)
    Pages free:                              815842.
    Pages active:                           1021366.
    Swapins:                               41973958.
    Swapouts:                              44622502.
    """
)


def shifted(swapins_delta, swapouts_delta):
    """QUIET with the two swap counters advanced by the given page counts."""
    return (
        QUIET.replace("41973958", str(41973958 + swapins_delta))
        .replace("44622502", str(44622502 + swapouts_delta))
    )


class SwapRateTest(unittest.TestCase):
    def test_a_quiet_host_reads_zero_and_is_sane(self):
        rate = host_memory_pressure.swap_megabytes_per_second(QUIET, QUIET, 10.0)

        self.assertEqual(rate, 0.0)
        self.assertEqual(host_memory_pressure.verdict_for(rate)[0], EXIT_SANE)

    def test_the_measured_storm_reads_void(self):
        """The 2026-09-13 window: 323,432 pages in and 406,817 out over 30s.

        A host over-committed enough to swap continuously, which is the
        condition this probe exists to refuse. It has to land in VOID with room
        to spare rather than on the boundary — hence the fixture, which pins the
        arithmetic against a real storm instead of an invented one.
        """
        rate = host_memory_pressure.swap_megabytes_per_second(
            QUIET, shifted(323432, 406817), 30.0
        )

        self.assertAlmostEqual(rate, 95.1, places=0)
        self.assertEqual(host_memory_pressure.verdict_for(rate)[0], EXIT_VOID)

    def test_both_directions_count(self):
        """Counting swapins alone would read a storm at half strength."""
        swapins_only = host_memory_pressure.swap_megabytes_per_second(
            QUIET, shifted(2560, 0), 10.0
        )
        both = host_memory_pressure.swap_megabytes_per_second(
            QUIET, shifted(2560, 2560), 10.0
        )

        self.assertAlmostEqual(swapins_only, 1.0, places=3)
        self.assertAlmostEqual(both, 2.0, places=3)

    def test_a_counter_going_backwards_is_not_a_verdict(self):
        with self.assertRaises(host_memory_pressure.CannotMeasure):
            host_memory_pressure.swap_megabytes_per_second(shifted(10, 10), QUIET, 10.0)

    def test_output_without_the_counters_is_not_a_verdict(self):
        with self.assertRaises(host_memory_pressure.CannotMeasure):
            host_memory_pressure.parse_vm_stat("total used free\n1 2 3\n")

    def test_the_page_size_comes_from_the_header(self):
        page_size, counters = host_memory_pressure.parse_vm_stat(
            QUIET.replace("page size of 4096 bytes", "page size of 16384 bytes")
        )

        self.assertEqual(page_size, 16384)
        self.assertEqual(counters["Swapins"], 41973958)


class ThresholdTest(unittest.TestCase):
    def test_the_bands_are_closed_at_the_bottom(self):
        """Exactly at a threshold is the worse verdict, not the better one."""
        self.assertEqual(
            host_memory_pressure.verdict_for(
                host_memory_pressure.DEFAULT_SWAP_MB_PER_SECOND_DEGRADED
            )[0],
            EXIT_DEGRADED,
        )
        self.assertEqual(
            host_memory_pressure.verdict_for(
                host_memory_pressure.DEFAULT_SWAP_MB_PER_SECOND_VOID
            )[0],
            EXIT_VOID,
        )

    def test_just_under_degraded_is_sane(self):
        self.assertEqual(
            host_memory_pressure.verdict_for(
                host_memory_pressure.DEFAULT_SWAP_MB_PER_SECOND_DEGRADED - 0.01
            )[0],
            EXIT_SANE,
        )

    def test_a_machine_can_carry_its_own_calibration(self):
        """The defaults are a starting point; the numbers belong to the host.

        A machine that needs a different line passes it (and keeps it in its own
        builder.json), so re-tuning one host never edits a constant in a repo
        that every other machine shares.
        """
        self.assertEqual(
            host_memory_pressure.verdict_for(
                5.0, degraded_threshold=10.0, void_threshold=50.0
            )[0],
            EXIT_SANE,
        )
        self.assertEqual(
            host_memory_pressure.verdict_for(
                5.0, degraded_threshold=1.0, void_threshold=4.0
            )[0],
            EXIT_VOID,
        )

    def test_the_calibration_flags_reach_the_verdict(self):
        """End to end: a quiet host asked for an absurd line still reads SANE."""
        result = subprocess.run(
            [
                sys.executable,
                str(REPO_ROOT / "tools" / "host_memory_pressure.py"),
                "--seconds",
                "0.05",
                "--degraded-mb-per-second",
                "1e12",
                "--void-mb-per-second",
                "1e12",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )

        self.assertIn(result.returncode, (EXIT_SANE, EXIT_CANNOT_MEASURE), result.stderr)

    def test_the_exit_codes_match_the_cpu_probe_contract(self):
        """Both probes feed the same gate, so their codes cannot drift apart."""
        cpu_probe = REPO_ROOT / "tools" / "host_cpu_share.py"
        spec = importlib.util.spec_from_file_location("host_cpu_share", cpu_probe)
        host_cpu_share = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(host_cpu_share)

        self.assertEqual(host_memory_pressure.EXIT_SANE, host_cpu_share.EXIT_SANE)
        self.assertEqual(host_memory_pressure.EXIT_DEGRADED, host_cpu_share.EXIT_DEGRADED)
        self.assertEqual(host_memory_pressure.EXIT_VOID, host_cpu_share.EXIT_VOID)


class RealProbeTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("vm_stat"), "vm_stat is macOS-only")
    def test_it_runs_and_answers_with_one_of_its_exit_codes(self):
        completed = subprocess.run(
            [sys.executable, str(PROBE), "--seconds", "0.2"],
            capture_output=True,
            text=True,
            timeout=60,
        )

        self.assertIn(completed.returncode, (EXIT_SANE, EXIT_DEGRADED, EXIT_VOID))
        self.assertIn("swap traffic", completed.stdout)

    @unittest.skipIf(shutil.which("vm_stat"), "this is the no-vm_stat path")
    def test_a_host_without_vm_stat_says_so_instead_of_reporting_sane(self):
        """A missing probe must never read as an all-clear."""
        completed = subprocess.run(
            [sys.executable, str(PROBE), "--seconds", "0.2"],
            capture_output=True,
            text=True,
            timeout=60,
        )

        self.assertEqual(completed.returncode, EXIT_CANNOT_MEASURE)


if __name__ == "__main__":
    unittest.main()
