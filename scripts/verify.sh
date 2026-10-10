#!/usr/bin/env bash
# Everything to pass before a release, stopping at the first failure: build.sh,
# the macOS suite many times over to catch flaky tests, the strict-concurrency
# build, the iOS suites on the newest and oldest runtimes, the Example UI tests,
# 90% line coverage and DocC. Test steps reuse build.sh's builds where the flags match.
#
# Environment:
#   WEBFONTKIT_RUNS       parallel macOS suite runs (default 10; 100 before a release flushes rare flakes)
#   WEBFONTKIT_UI_RUNS    Example UI test iterations (default 3)
#   WEBFONTKIT_IOS_MAJOR  iOS major version to test on (default: newest installed)
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$ROOT"

[ $# -eq 0 ] || { echo "usage: $0 (settings come from the environment; see the header)" >&2; exit 2; }
RUNS="${WEBFONTKIT_RUNS:-10}"
UI_RUNS="${WEBFONTKIT_UI_RUNS:-3}"
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || fail "WEBFONTKIT_RUNS must be a positive integer, not '$RUNS'"
[[ "$UI_RUNS" =~ ^[1-9][0-9]*$ ]] || fail "WEBFONTKIT_UI_RUNS must be a positive integer, not '$UI_RUNS'"
TIMEOUT=900
SKIP_PERF=(--skip WebFontKitPerformanceTests)

"$ROOT/scripts/build.sh"
require_ios_simulator
require_oldest_simulator

log "macOS suite, $RUNS parallel runs"
for i in $(seq 1 "$RUNS"); do
    if ! with_timeout "$TIMEOUT" swift test --skip-build "${SKIP_PERF[@]}" >"$WORK/test-macos.log" 2>&1; then
        tail -60 "$WORK/test-macos.log"
        fail "run $i of $RUNS failed (log: $WORK/test-macos.log)"
    fi
    printf '.'
done
echo " $RUNS/$RUNS passed"

# Serial, which also catches tests that only pass in parallel; instrumented, so
# it doubles as the coverage run.
log "macOS suite, serial, with line coverage"
with_timeout "$TIMEOUT" swift test --no-parallel --enable-code-coverage "${SKIP_PERF[@]}" >"$WORK/test-serial.log" 2>&1 \
    || { tail -60 "$WORK/test-serial.log"; fail "serial run failed (log: $WORK/test-serial.log)"; }
python3 - "$(swift test --show-codecov-path)" "$WORK/coverage.txt" <<'EOF' || fail "line coverage is below 90% (see $WORK/coverage.txt)"
import json, sys
files = [f for f in json.load(open(sys.argv[1]))["data"][0]["files"] if "/Sources/WebFontKit/" in f["filename"]]
if not files:
    sys.exit("no coverage data for Sources/WebFontKit")
covered = sum(f["summary"]["lines"]["covered"] for f in files)
total = sum(f["summary"]["lines"]["count"] for f in files)
with open(sys.argv[2], "w") as report:
    for f in sorted(files, key=lambda f: f["summary"]["lines"]["percent"]):
        report.write("%6.2f%%  %s\n" % (f["summary"]["lines"]["percent"], f["filename"].split("/Sources/")[1]))
percent = 100 * covered / total
print("Line coverage: %.2f%% (%d of %d lines)" % (percent, covered, total))
sys.exit(0 if percent >= 90 else 1)
EOF

# A separate build folder, so these flags don't invalidate the main build.
log "macOS suite, NonisolatedNonsendingByDefault build"
swiftpm_no_warnings test-nonsending with_timeout "$TIMEOUT" swift test --scratch-path .build/nonsending "${SKIP_PERF[@]}" \
    -Xswiftc -warnings-as-errors -Xswiftc -enable-upcoming-feature -Xswiftc NonisolatedNonsendingByDefault

log "iOS $SIMULATOR_VERSION: every test target, performance as a smoke run (no baseline)"
xcodebuild_tests test-ios with_timeout "$TIMEOUT" xcodebuild test-without-building -scheme WebFontKit \
    -destination "platform=iOS Simulator,id=$SIMULATOR"

log "iOS $OLDEST_VERSION (oldest installed): integration tests"
xcodebuild_tests test-ios-oldest with_timeout "$TIMEOUT" xcodebuild test-without-building -scheme WebFontKit \
    -destination "platform=iOS Simulator,id=$OLDEST" -only-testing:WebFontKitIntegrationTests

log "iOS $SIMULATOR_VERSION: Example UI tests, $UI_RUNS iterations"
xcodebuild_tests test-ui with_timeout "$((TIMEOUT * 2))" xcodebuild test-without-building \
    -project Example/WebFontKitExample.xcodeproj -scheme ExampleApp -destination "platform=iOS Simulator,id=$SIMULATOR" \
    -test-iterations "$UI_RUNS" -run-tests-until-failure

log "DocC, warnings as errors"
xcodebuild_no_warnings docbuild xcodebuild docbuild -scheme WebFontKit -destination 'generic/platform=iOS' \
    OTHER_DOCC_FLAGS='--warnings-as-errors'

log "verify.sh: PASS"
