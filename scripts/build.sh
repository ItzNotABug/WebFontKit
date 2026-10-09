#!/usr/bin/env bash
# Builds everything with zero warnings: the package and its tests on macOS and
# for the iOS simulator, and the Example app with its UI tests. Warnings become
# errors on the command line, never in Package.swift. Uses the newest installed
# iOS; set WEBFONTKIT_IOS_MAJOR (for example 26) to pick another.
set -euo pipefail
source "$(dirname "$0")/common.sh"
cd "$ROOT"
command -v xcodegen >/dev/null || fail "needs XcodeGen for the Example app (brew install xcodegen)"

log "Package.swift has no unsafeFlags"
! swift package dump-package | grep -q unsafeFlags || fail "Package.swift contains unsafeFlags, which SwiftPM rejects in dependencies"

log "macOS: package and tests"
swiftpm_no_warnings build-macos swift build --build-tests -Xswiftc -warnings-as-errors

require_ios_simulator
DESTINATION="platform=iOS Simulator,id=$SIMULATOR"

log "iOS $SIMULATOR_VERSION: package and tests"
xcodebuild_no_warnings build-ios xcodebuild build-for-testing -scheme WebFontKit -destination "$DESTINATION"

log "iOS $SIMULATOR_VERSION: Example app and UI tests"
(cd Example && xcodegen generate --quiet)
xcodebuild_no_warnings build-example xcodebuild build-for-testing \
    -project Example/WebFontKitExample.xcodeproj -scheme ExampleApp -destination "$DESTINATION"

log "build.sh: PASS, zero warnings"
