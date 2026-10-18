#!/usr/bin/env python3
"""Run app and tooling suites concurrently, with uncached timing and coverage."""

from __future__ import annotations

import argparse
import asyncio
from dataclasses import asdict, dataclass, field
import json
import os
from pathlib import Path
import shutil
import re
import statistics
import sys
import time
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / ".test-results"


@dataclass
class SuiteResult:
    name: str
    workers: int = 1
    exit_code: int = 0
    phases: dict[str, float] = field(default_factory=dict)
    logs: list[str] = field(default_factory=list)
    coverage: dict = field(default_factory=dict)
    tests: list[dict] = field(default_factory=list)
    tests_passed: bool | None = None
    test_count: int | None = None


class TestRunner:
    def __init__(self, output: Path):
        self.output = output
        self.output.mkdir(parents=True, exist_ok=True)

    async def command(self, result: SuiteResult, phase: str, command: list[str],
                      cwd: Path = ROOT) -> bool:
        log = self.output / f"{result.name}-{phase}.log"
        started = time.monotonic()
        try:
            with log.open("wb") as output:
                process = await asyncio.create_subprocess_exec(
                    *command, cwd=cwd, stdout=output, stderr=asyncio.subprocess.STDOUT)
                try:
                    code = await process.wait()
                except asyncio.CancelledError:
                    process.terminate()
                    await process.wait()
                    raise
        except OSError as error:
            log.write_text(f"Could not launch {command[0]}: {error}\n")
            code = 127
        result.phases[phase] = time.monotonic() - started
        result.logs.append(str(log))
        if code and not result.exit_code:
            result.exit_code = code
        return code == 0

    async def android(self, workers: int) -> SuiteResult:
        result = SuiteResult("android", workers)
        cwd = ROOT / "android"
        gradle = [str(cwd / "gradlew"), "--console=plain", f"-PtestWorkers={workers}"]
        if not await self.command(result, "build", gradle + [":app:compileDebugUnitTestSources"], cwd):
            return result
        # The property disables only test up-to-date checks. Compilation remains cached.
        tests_passed = await self.command(result, "tests", gradle + [
            "-PforceTestExecution=true", ":app:testDebugUnitTest"], cwd)
        result.tests_passed = tests_passed
        if not tests_passed:
            return result
        report = cwd / "app/build/reports/jacoco/debugUnitTestCoverageReport/debugUnitTestCoverageReport.xml"
        report.unlink(missing_ok=True)
        await self.command(result, "coverage", gradle + [
            ":app:debugUnitTestCoverageReport", ":app:verifyDebugUnitTestCoverage"], cwd)
        if report.exists():
            shutil.copyfile(report, self.output / "android-coverage.xml")
            document = ET.parse(report).getroot()
            counters = {item.get("type"): item for item in document.findall("counter")}
            lines = counters.get("LINE")
            if lines is not None:
                covered, missed = int(lines.get("covered", "0")), int(lines.get("missed", "0"))
                result.coverage = {"covered": covered, "total": covered + missed}
            result.coverage["files"] = [
                {"path": f"{package.get('name')}/{source.get('name')}",
                 "covered": int(counter.get("covered", "0")),
                 "total": int(counter.get("covered", "0")) + int(counter.get("missed", "0")),
                 "uncovered_lines": [int(line.get("nr")) for line in source.findall("line")
                                     if int(line.get("mi", "0")) > 0 and int(line.get("ci", "0")) == 0]}
                for package in document.findall("package")
                for source in package.findall("sourcefile")
                for counter in source.findall("counter") if counter.get("type") == "LINE"
            ]
        for path in sorted((cwd / "app/build/test-results/testDebugUnitTest").glob("TEST-*.xml")):
            for case in ET.parse(path).getroot().findall("testcase"):
                result.tests.append({"class": case.get("classname"), "name": case.get("name"),
                                     "seconds": float(case.get("time", "0"))})
        self.require_coverage(result)
        return result

    async def macos(self, workers: int) -> SuiteResult:
        result = SuiteResult("macos", workers)
        if not await self.command(result, "build", ["xcrun", "swift", "build", "--build-tests",
                                                     "--enable-code-coverage"], ROOT / "macos"):
            return result
        await self.command(result, "tests-and-coverage", [sys.executable,
            str(ROOT / "macos/scripts/check_macos_coverage.py"), "--skip-build", "--workers", str(workers)])
        for source, destination in [("macos-coverage-summary.json", "coverage"),
                                    ("macos-coverage-timing.json", "timing")]:
            path = ROOT / "macos/.build" / source
            if path.exists():
                data = json.loads(path.read_text())
                if destination == "coverage":
                    result.coverage = data
                else:
                    result.phases.update(data)
                (self.output / source).write_text(path.read_text())
        test_xml = ROOT / "macos/.build/macos-tests.xml"
        if test_xml.exists():
            shutil.copyfile(test_xml, self.output / test_xml.name)
            cases = list(ET.parse(test_xml).getroot().iter("testcase"))
            result.tests_passed = bool(cases) and not any(
                case.find("failure") is not None or case.find("error") is not None for case in cases)
            for case in cases:
                result.tests.append({"class": case.get("classname"), "name": case.get("name"),
                                     "seconds": float(case.get("time", "0"))})
        test_log = ROOT / "macos/.build/macos-coverage-tests.log"
        if test_log.exists():
            shutil.copyfile(test_log, self.output / test_log.name)
            # Some SwiftPM backends emit xUnit only for parallel XCTest runs.
            if not result.tests:
                result.tests = self.read_xctest_log(test_log.read_text(errors="replace"))
                result.tests_passed = bool(result.tests) and all(case["passed"] for case in result.tests)
        self.require_coverage(result)
        return result

    @staticmethod
    def read_xctest_log(log: str) -> list[dict]:
        pattern = r"Test Case '-\[([^ ]+) ([^\]]+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)"
        return [{"class": match[0], "name": match[1], "seconds": float(match[3]),
                 "passed": match[2] != "failed"} for match in re.findall(pattern, log)]

    @staticmethod
    def require_coverage(result: SuiteResult) -> None:
        if (not result.coverage.get("total")
                or result.coverage.get("covered") != result.coverage.get("total")
                or result.coverage.get("missing_sources")):
            result.exit_code = result.exit_code or 1

    async def tooling(self, name: str, path: str) -> SuiteResult:
        result = SuiteResult(name)
        await self.command(result, "tests", [sys.executable, "-m", "unittest", "discover",
                                             "-s", path, "-p", "test_*.py"])
        result.tests_passed = result.exit_code == 0
        log = Path(result.logs[-1]).read_text(errors="replace")
        count = re.search(r"Ran (\d+) tests? in", log)
        if count:
            result.test_count = int(count.group(1))
        return result

    async def run(self, platform: str, android_workers: int, macos_workers: int) -> dict:
        started = time.monotonic()
        jobs = []
        if platform in ("all", "android"):
            jobs.append(self.android(android_workers))
        if platform in ("all", "macos"):
            jobs.append(self.macos(macos_workers))
        if platform in ("all", "tooling"):
            jobs.extend([self.tooling("release-tooling", "scripts/release"),
                         self.tooling("macos-tooling", "macos/scripts"),
                         self.tooling("test-runner", "scripts/testing")])
        # Each suite completes even if another fails. Unexpected parser errors also
        # become failures after all other children have been awaited.
        outcomes = await asyncio.gather(*jobs, return_exceptions=True)
        results = []
        for outcome in outcomes:
            if isinstance(outcome, BaseException):
                results.append({"name": "runner-error", "exit_code": 1, "error": str(outcome)})
            else:
                results.append(asdict(outcome))
        summary = {"wall_seconds": time.monotonic() - started, "suites": results}
        (self.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print("Suite                 Workers  Result  Build(s)  Test(s)  Coverage(s)")
        for result in results:
            phases = result.get("phases", {})
            print(f"{result['name']:<22} {result.get('workers', 1):>6}  "
                  f"{'PASS' if result['exit_code'] == 0 else 'FAIL':<6}  "
                  f"{phases.get('build', 0):>8.3f}  "
                  f"{phases.get('tests_seconds', phases.get('tests', 0)):>7.3f}  "
                  f"{phases.get('coverage_seconds', phases.get('coverage', 0)):>11.3f}")
        print(f"Total wall time: {summary['wall_seconds']:.3f}s; artifacts: {self.output}")
        return summary


def positive(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("all", "android", "macos", "tooling"), default="all")
    parser.add_argument("--android-workers", type=positive, default=1)
    parser.add_argument("--macos-workers", type=positive, default=1)
    parser.add_argument("--repeat", type=positive, default=1)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    cpu_count = os.cpu_count() or 1
    summaries = []
    for iteration in range(args.repeat):
        output = args.output / f"run-{iteration + 1}"
        runner = TestRunner(output.resolve())
        summaries.append(await runner.run(args.platform, min(args.android_workers, cpu_count),
                                          min(args.macos_workers, cpu_count)))
    if len(summaries) > 1:
        print(f"Median wall time: {statistics.median(s['wall_seconds'] for s in summaries):.3f}s")
    return int(any(suite["exit_code"] for summary in summaries for suite in summary["suites"]))


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        raise SystemExit(130)
