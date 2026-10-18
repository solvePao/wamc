"""Behavior checks for concurrent test orchestration and coverage validation."""

import asyncio
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from run_tests import SuiteResult, TestRunner


class RunnerTests(unittest.IsolatedAsyncioTestCase):
    def test_serial_xctest_results_are_counted_without_xunit(self):
        cases = TestRunner.read_xctest_log(
            "Test Case '-[AndroidWebcamTests.ExampleTests testSuccess]' passed (0.012 seconds).\n"
            "Test Case '-[AndroidWebcamTests.ExampleTests testFailure]' failed (0.100 seconds).\n"
            "Executed 2 tests, with 1 failure\n")
        self.assertEqual(len(cases), 2)
        self.assertEqual(cases[0]["name"], "testSuccess")
        self.assertEqual(cases[0]["seconds"], .012)
        self.assertTrue(cases[0]["passed"])
        self.assertFalse(cases[1]["passed"])

    async def test_commands_overlap_and_keep_independent_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runner = TestRunner(root)
            # Each child creates its marker and waits for the other. Serial
            # execution fails, so this proves overlap without a speed assertion.
            script = (
                "import pathlib,sys,time; "
                "mine,other=map(pathlib.Path,sys.argv[1:]); mine.touch(); "
                "deadline=time.monotonic()+3\n"
                "while not other.exists() and time.monotonic()<deadline: time.sleep(.005)\n"
                "print(mine.name); sys.exit(0 if other.exists() else 1)"
            )
            left, right = SuiteResult("left"), SuiteResult("right")
            results = await asyncio.gather(
                runner.command(left, "tests", [sys.executable, "-c", script, str(root / "a"), str(root / "b")]),
                runner.command(right, "tests", [sys.executable, "-c", script, str(root / "b"), str(root / "a")]))
            self.assertEqual(results, [True, True])
            self.assertEqual((root / "left-tests.log").read_text().strip(), "a")
            self.assertEqual((root / "right-tests.log").read_text().strip(), "b")

    async def test_failure_does_not_cancel_other_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = TestRunner(Path(directory))
            completed = []

            async def tooling(name, path):
                await asyncio.sleep(0)
                completed.append(name)
                return SuiteResult(name, exit_code=2 if name == "release-tooling" else 0)

            with patch.object(runner, "tooling", side_effect=tooling):
                summary = await runner.run("tooling", 1, 1)
            self.assertEqual(len(completed), 3)
            self.assertEqual([s["exit_code"] for s in summary["suites"]], [2, 0, 0])
            self.assertTrue((Path(directory) / "summary.json").exists())

    async def test_missing_executable_is_reported(self):
        with tempfile.TemporaryDirectory() as directory:
            runner = TestRunner(Path(directory))
            result = SuiteResult("missing")
            self.assertFalse(await runner.command(result, "tests", [str(Path(directory) / "absent")]))
            self.assertEqual(result.exit_code, 127)

    def test_coverage_rejects_empty_partial_missing_and_rounded_results(self):
        for coverage in ({}, {"covered": 0, "total": 0},
                         {"covered": 99999, "total": 100000},
                         {"covered": 1, "total": 1, "missing_sources": ["file.swift"]}):
            with self.subTest(coverage=coverage):
                result = SuiteResult("app", coverage=coverage)
                TestRunner.require_coverage(result)
                self.assertEqual(result.exit_code, 1)
        result = SuiteResult("app", coverage={"covered": 10, "total": 10})
        TestRunner.require_coverage(result)
        self.assertEqual(result.exit_code, 0)


if __name__ == "__main__":
    unittest.main()
