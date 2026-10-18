#!/usr/bin/env python3
"""Run macOS unit tests and enforce 90% line coverage for production Swift."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


THRESHOLD_PERCENT = 90.0
MACOS_DIR = Path(__file__).resolve().parents[1]
REPO_DIR = MACOS_DIR.parent
BUILD_DIR = MACOS_DIR / ".build"
TEST_LOG = BUILD_DIR / "macos-coverage-tests.log"
COVERAGE_JSON = BUILD_DIR / "macos-coverage.json"
SOURCE_ALIASES = {
    (MACOS_DIR / "Entrypoints/main.swift").resolve():
        (MACOS_DIR / "Tests/WAMCLauncherTestSupport/WAMCRunner.swift").resolve(),
}


def run_tests() -> bool:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    with TEST_LOG.open("w", encoding="utf-8") as output:
        result = subprocess.run(
            ["xcrun", "swift", "test", "--enable-code-coverage"],
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
    build_path = subprocess.run(
        ["xcrun", "swift", "build", "--show-bin-path"],
        cwd=MACOS_DIR, capture_output=True, text=True, check=True,
    )
    bin_dir = Path(build_path.stdout.strip())
    profiles = [path for path in bin_dir.rglob("default.profdata") if path.is_file()]
    binaries = sorted(path for path in bin_dir.glob("*.xctest/Contents/MacOS/*") if path.is_file())
    if not profiles or not binaries:
        raise RuntimeError(f"SwiftPM coverage profile or test executable was not found under {bin_dir}")
    profile = max(profiles, key=lambda path: path.stat().st_mtime)
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
    line_counts = [
        files[path].get("summary", {}).get("lines", {})
        for path in measured
    ]
    covered = sum(count.get("covered", 0) for count in line_counts)
    total = sum(count.get("count", 0) for count in line_counts)
    percent = 100.0 * covered / total if total else 0.0

    print(f"macOS production line coverage: {covered}/{total} executable lines ({percent:.2f}%)")
    print(f"Coverage threshold: {THRESHOLD_PERCENT:.0f}%")
    if missing:
        print(f"Production Swift files absent from test instrumentation: {len(missing)}")
        for path in missing:
            print(f"  - {path.relative_to(REPO_DIR)}")
    if percent < THRESHOLD_PERCENT or missing:
        print(f"Coverage export: {COVERAGE_JSON}")
        return False
    return True


def main() -> int:
    if not run_tests():
        return 1
    try:
        report = read_coverage()
        return 0 if enforce_coverage(report) else 1
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Could not verify macOS line coverage: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
