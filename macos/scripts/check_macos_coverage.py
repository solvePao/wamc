#!/usr/bin/env python3
"""Run isolated macOS tests and enforce complete production line coverage."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path


THRESHOLD_PERCENT = 100.0
MACOS_DIR = Path(__file__).resolve().parents[1]
REPO_DIR = MACOS_DIR.parent
BUILD_DIR = MACOS_DIR / ".build"
TEST_LOG = BUILD_DIR / "macos-coverage-tests.log"
TEST_XML = BUILD_DIR / "macos-tests.xml"
COVERAGE_JSON = BUILD_DIR / "macos-coverage.json"
COVERAGE_SUMMARY = BUILD_DIR / "macos-coverage-summary.json"
SOURCE_ALIASES = {
    (MACOS_DIR / "Entrypoints/main.swift").resolve():
        (MACOS_DIR / "Tests/WAMCLauncherTestSupport/WAMCRunner.swift").resolve(),
}


def binary_directory() -> Path:
    build_path = subprocess.run(
        ["xcrun", "swift", "build", "--show-bin-path"],
        cwd=MACOS_DIR, capture_output=True, text=True, check=True,
    )
    return Path(build_path.stdout.strip())


def clear_profiles(bin_dir: Path) -> None:
    # Resolve SwiftPM's active layout rather than guessing the target triple.
    # Xcode's native backend also uses .build/out/Products/Debug/codecov.
    for profile in (bin_dir / "codecov").glob("*"):
        if profile.suffix in (".profraw", ".profdata"):
            profile.unlink()


def run_tests(workers: int, skip_build: bool = False) -> bool:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    for old_report in (COVERAGE_JSON, COVERAGE_SUMMARY, TEST_XML, BUILD_DIR / "macos-coverage-timing.json"):
        old_report.unlink(missing_ok=True)
    # SwiftPM merges this run's per-process profiles. Remove old profiles so a
    # previous worker cannot contribute coverage to a later run.
    clear_profiles(binary_directory())
    command = ["xcrun", "swift", "test", "--enable-code-coverage", "--xunit-output", str(TEST_XML)]
    if skip_build:
        command.append("--skip-build")
    if workers > 1:
        command.extend(["--parallel", "--num-workers", str(workers)])
    else:
        command.append("--no-parallel")
    with TEST_LOG.open("w", encoding="utf-8") as output:
        result = subprocess.run(
            command,
            cwd=MACOS_DIR,
            stdout=output,
            stderr=subprocess.STDOUT,
            check=False,
        )
    if result.returncode == 0:
        return True
    print(f"macOS tests failed; full output: {TEST_LOG}", file=sys.stderr)
    print("".join(TEST_LOG.read_text(encoding="utf-8", errors="replace").splitlines(True)[-60:]), file=sys.stderr)
    return False


def production_sources() -> set[Path]:
    roots = (MACOS_DIR / "Sources", MACOS_DIR / "CameraExtension", MACOS_DIR / "Entrypoints")
    return {
        path.resolve()
        for root in roots
        for path in root.rglob("*.swift")
        if path.is_file()
    }


def read_coverage() -> dict:
    bin_dir = binary_directory()
    profiles = [path for path in bin_dir.rglob("default.profdata") if path.is_file()]
    binaries = sorted(path for path in bin_dir.glob("*.xctest/Contents/MacOS/*") if path.is_file())
    if len(profiles) != 1 or not binaries:
        raise RuntimeError(f"SwiftPM coverage profile or test executable was not found under {bin_dir}")
    profile = profiles[0]
    objects = [argument for binary in binaries[1:] for argument in ("-object", str(binary))]
    with COVERAGE_JSON.open("w", encoding="utf-8") as output:
        result = subprocess.run(
            ["xcrun", "llvm-cov", "export", "-format=text", f"-instr-profile={profile}", str(binaries[0]), *objects],
            cwd=MACOS_DIR,
            stdout=output,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    if result.returncode != 0:
        raise RuntimeError(f"llvm-cov export failed: {result.stderr.strip()}")
    return json.loads(COVERAGE_JSON.read_text(encoding="utf-8"))


def enforce_coverage(report: dict) -> bool:
    files: dict[Path, dict] = {}
    for section in report.get("data", []):
        for entry in section.get("files", []):
            path = Path(entry["filename"])
            if not path.is_absolute():
                path = REPO_DIR / path
            files[path.resolve()] = entry

    expected = production_sources()
    # SwiftPM forbids one source path from belonging to both an executable and
    # a test-support target. The support copy has the same launcher body and
    # compiles with WAMC_COVERAGE_TESTING to suppress only the @main attribute.
    for source, support_source in SOURCE_ALIASES.items():
        def launcher_body(path):
            return "\n".join(line for line in path.read_text().splitlines()
                             if not line.startswith("#sourceLocation"))
        if launcher_body(source) != launcher_body(support_source):
            raise ValueError("Coverage launcher copy differs from the production launcher")
        if source in expected and source not in files and support_source in files:
            files[source] = files[support_source]
    measured = expected.intersection(files)
    missing = sorted(expected - measured)
    line_counts = [files[path]["summary"]["lines"] for path in measured]
    if any(not isinstance(count.get("count"), int)
           or not isinstance(count.get("covered"), int)
           or not 0 <= count["covered"] <= count["count"]
           for count in line_counts):
        raise ValueError("Invalid production line coverage counters")
    covered = sum(count.get("covered", 0) for count in line_counts)
    total = sum(count.get("count", 0) for count in line_counts)
    percent = 100.0 * covered / total if total else 0.0

    print(f"macOS production line coverage: {covered}/{total} executable lines ({percent:.2f}%)")
    print(f"Coverage threshold: {THRESHOLD_PERCENT:.0f}%")
    details = [
        {"path": str(path.relative_to(REPO_DIR)),
         "covered": files[path]["summary"]["lines"]["covered"],
         "total": files[path]["summary"]["lines"]["count"]}
        for path in sorted(measured)
    ]
    COVERAGE_SUMMARY.write_text(json.dumps({
        "covered": covered, "total": total,
        "missing_sources": [str(path.relative_to(REPO_DIR)) for path in missing],
        "files": details,
    }, indent=2) + "\n", encoding="utf-8")
    if missing:
        print(f"Production Swift files absent from test instrumentation: {len(missing)}")
        for path in missing:
            print(f"  - {path.relative_to(REPO_DIR)}")
    if total == 0 or covered != total or missing:
        for entry in details:
            if entry["covered"] != entry["total"]:
                print(f"  {entry['path']}: {entry['total'] - entry['covered']} uncovered lines")
        print(f"Coverage export: {COVERAGE_JSON}")
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if args.workers < 1:
        parser.error("--workers must be positive")
    started = time.monotonic()
    try:
        if not run_tests(min(args.workers, os.cpu_count() or 1), args.skip_build):
            return 1
        tests_finished = time.monotonic()
        report = read_coverage()
        passed = enforce_coverage(report)
        timings = {"tests_seconds": tests_finished - started,
                   "coverage_seconds": time.monotonic() - tests_finished}
        (BUILD_DIR / "macos-coverage-timing.json").write_text(json.dumps(timings) + "\n")
        return 0 if passed else 1
    except (OSError, KeyError, TypeError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Could not verify macOS line coverage: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
