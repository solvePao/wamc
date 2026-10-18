# Tests, concurrency, and coverage

Run every suite from the repository root:

```sh
python3 scripts/testing/run_tests.py
```

The runner starts Android, macOS, and Python tooling subprocesses concurrently.
It waits for every suite, writes independent logs, and exits nonzero when any
test or coverage gate fails. It requires JDK 17, Android SDK 35, and the macOS
Xcode toolchain. Tests run locally only. GitHub Actions builds both apps and
packages releases without invoking tests or coverage gates.

## Workers and repeatable timing

```sh
python3 scripts/testing/run_tests.py --android-workers 2 --macos-workers 4
python3 scripts/testing/run_tests.py --android-workers 1 --macos-workers 1 --repeat 3
python3 scripts/testing/run_tests.py --platform android --android-workers 2 --repeat 3
python3 scripts/testing/run_tests.py --platform macos --macos-workers 4 --repeat 3
```

Use one worker for a serial baseline. Compare Android counts 1 and 2, and macOS
counts 1, 2, and 4. Run on an otherwise idle machine after one warm-up. Select
the lowest median warm runtime; prefer fewer workers within 5%. Compilation
and dependency downloads belong to build timing, not test execution timing.
Android test tasks explicitly bypass up-to-date results during runner calls;
compilation remains incremental. macOS tests run with `--skip-build` after the
instrumented test build. Repetition never runs two copies of the same platform
against one build directory simultaneously.

JUnit methods remain serial within each JVM. Gradle distributes classes across
worker JVMs. SwiftPM uses separate test processes; asynchronous tests await
completion signals while UI work remains on the main actor. Tests must own
their sockets, temporary files, preferences, callbacks, and teardown.

Both platforms default to one worker because measured local runs favored fewer processes.
Two-worker execution remains supported and passed five consecutive runs with
complete Android line coverage. Android and macOS commands still overlap in the
runner. macOS also supports two- and four-worker execution; its complete
production coverage target remains unmet, and its strict gate reports failure.

## Artifacts and gates

Each run writes `.test-results/run-N/summary.json`, phase logs, Android test
identifiers and durations, and production coverage totals. Override the root
with `--output /absolute/path`. Platform reports remain at:

- Android: `android/app/build/reports/jacoco/debugUnitTestCoverageReport/`
- Android JUnit XML: `android/app/build/test-results/testDebugUnitTest/`
- macOS: `macos/.build/macos-coverage.json`
- macOS source summary: `macos/.build/macos-coverage-summary.json`
- macOS test log: `macos/.build/macos-coverage-tests.log`

Both app gates require every executable production line to be covered. Empty
or incomplete production reports fail. The macOS checker removes prior raw
profiles before execution and reads SwiftPM's merged profile, so old worker
coverage cannot satisfy a later run. The launcher support copy must match the
production source. Generated Android resources and BuildConfig retain their
existing exclusions; UI and platform adapters remain in coverage scope.

Run a platform gate directly:

```sh
cd android
./gradlew -PtestWorkers=2 -PforceTestExecution=true :app:testDebugUnitTest :app:debugUnitTestCoverageReport :app:verifyDebugUnitTestCoverage
```

```sh
python3 macos/scripts/check_macos_coverage.py --workers 4
```

Line coverage is enforced by exact counts, not rounded percentages. Android
branch counters remain in JaCoCo XML/HTML; no 100% branch requirement applies.
Python release, signing, coverage-checker, and runner tests must pass, but their
source files are outside the app production coverage denominator.

## Packaging and automation

Run the local test command before pushing or tagging a release. The Build and
Release workflows contain build, signing, and artifact checks only; a green
GitHub check does not certify local test or coverage results.

Local Mac bundle builds run the coverage gate by default. The release workflow
sets `WAMC_RUN_TESTS=false` explicitly to prevent packaging from indirectly
launching tests. `WAMC_COVERAGE_VERIFIED=true` remains available to local callers
that have already passed the gate for the same source tree.
