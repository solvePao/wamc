"""Coverage gates must fail closed, including values rounded to 100%."""

import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check_macos_coverage as coverage


class CoverageGateTests(unittest.TestCase):
    def test_profile_cleanup_handles_native_and_legacy_layouts(self):
        with tempfile.TemporaryDirectory() as directory:
            for relative in ("arm64-apple-macosx/debug", "out/Products/Debug"):
                bin_dir = Path(directory) / relative
                profiles = bin_dir / "codecov"
                profiles.mkdir(parents=True)
                for name in ("default.profdata", "worker-1.profraw", "worker-2.profraw", "keep.json"):
                    (profiles / name).write_text("old data")
                coverage.clear_profiles(bin_dir)
                self.assertEqual([path.name for path in profiles.iterdir()], ["keep.json"])

    def test_failed_test_run_cannot_leave_old_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reports = [root / name for name in ("coverage.json", "summary.json", "tests.xml", "macos-coverage-timing.json")]
            for report in reports:
                report.write_text("stale")
            with patch.object(coverage, "BUILD_DIR", root), \
                    patch.object(coverage, "COVERAGE_JSON", reports[0]), \
                    patch.object(coverage, "COVERAGE_SUMMARY", reports[1]), \
                    patch.object(coverage, "TEST_XML", reports[2]), \
                    patch.object(coverage, "TEST_LOG", root / "test.log"), \
                    patch.object(coverage, "binary_directory", return_value=root), \
                    patch.object(coverage.subprocess, "run", return_value=type("Result", (), {"returncode": 1})()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertFalse(coverage.run_tests(2, skip_build=True))
            self.assertTrue(all(not report.exists() for report in reports))

    def check_report(self, covered, total, include_file=True):
        source = coverage.MACOS_DIR / "Sources" / "Example.swift"
        entries = [{"filename": str(source), "summary": {"lines": {
            "covered": covered, "count": total}}}] if include_file else []
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(coverage, "production_sources", return_value={source}), \
                patch.object(coverage, "SOURCE_ALIASES", {}), \
                patch.object(coverage, "COVERAGE_SUMMARY", Path(directory) / "summary.json"), \
                contextlib.redirect_stdout(io.StringIO()):
            return coverage.enforce_coverage({"data": [{"files": entries}]})

    def test_complete_report_passes(self):
        self.assertTrue(self.check_report(3, 3))

    def test_empty_missing_and_rounded_report_fail(self):
        self.assertFalse(self.check_report(0, 0))
        self.assertFalse(self.check_report(1, 1, include_file=False))
        self.assertFalse(self.check_report(99999, 100000))

    def test_invalid_counters_fail(self):
        for covered, total in ((2, 1), (-1, 1), (1, "1")):
            with self.subTest(covered=covered, total=total), self.assertRaises(ValueError):
                self.check_report(covered, total)


if __name__ == "__main__":
    unittest.main()
