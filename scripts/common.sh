# Shared helpers for build.sh, verify.sh and CI. Source it; don't run it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WEBFONTKIT_WORK_DIR:-$ROOT/.build/gates}"
mkdir -p "$WORK"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }

# Runs a command with a time limit in seconds. The command gets its own process
# group, so a timeout also ends what it started (xctest, simulator helpers); a
# hang that ignores cancellation would otherwise never end.
with_timeout() {
    local seconds="$1"; shift
    perl -e '
        my $seconds = shift;
        my $pid = fork // die "fork: $!";
        if ($pid == 0) { setpgrp(0, 0); exec @ARGV or die "exec: $!" }
        $SIG{INT} = $SIG{TERM} = sub { kill "TERM", -$pid; exit 130 };
        $SIG{ALRM} = sub { print STDERR "timed out after ${seconds}s\n"; kill "TERM", -$pid; sleep 5; kill "KILL", -$pid; exit 124 };
        alarm $seconds;
        waitpid($pid, 0);
        exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$seconds" "$@"
}

# Prints "<udid> <version>" for an available iPhone simulator on an iOS 17+
# runtime, or nothing. $1 is "newest" or "oldest"; $2, if set, keeps only that
# major version.
pick_ios_simulator() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
mode, major = sys.argv[1], sys.argv[2]
best = None
for runtime, items in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.split(".iOS-")[1].split("-"))
    if version < (17,) or (major and str(version[0]) != major):
        continue
    phones = [d for d in items if d["name"].startswith("iPhone") and d["isAvailable"]]
    better = best is None or (version > best[0] if mode == "newest" else version < best[0])
    if phones and better:
        best = (version, phones[0]["udid"])
if best:
    print(best[1], ".".join(map(str, best[0])))
' "$1" "${2:-}"
}

# Sets SIMULATOR and SIMULATOR_VERSION: the newest iOS, or $WEBFONTKIT_IOS_MAJOR's newest.
require_ios_simulator() {
    read -r SIMULATOR SIMULATOR_VERSION <<<"$(pick_ios_simulator newest "${WEBFONTKIT_IOS_MAJOR:-}")"
    [ -n "${SIMULATOR:-}" ] || fail "no iPhone simulator on iOS ${WEBFONTKIT_IOS_MAJOR:-17 or later} is installed"
}

# Sets OLDEST and OLDEST_VERSION: the oldest runtime at or above the deployment target.
require_oldest_simulator() {
    read -r OLDEST OLDEST_VERSION <<<"$(pick_ios_simulator oldest)"
    [ -n "${OLDEST:-}" ] || fail "no iPhone simulator on iOS 17 or later is installed"
}

# Runs a SwiftPM build into a log, failing on a nonzero exit or any "warning:"
# line: SwiftPM's own package warnings don't fail a -warnings-as-errors build.
swiftpm_no_warnings() {
    local name="$1"; shift
    local out="$WORK/$name.log"
    if ! "$@" >"$out" 2>&1; then
        tail -40 "$out"
        fail "$name failed (log: $out)"
    fi
    if grep -q 'warning:' "$out"; then
        grep 'warning:' "$out"
        fail "$name printed warnings"
    fi
}

# Runs an xcodebuild build into a fresh result bundle, failing on a nonzero exit
# or a nonzero warningCount. The log isn't grepped: App Intents metadata prints
# a harmless "warning:" line.
xcodebuild_no_warnings() {
    local name="$1"; shift
    local bundle="$WORK/$name.xcresult" out="$WORK/$name.log"
    rm -rf "$bundle"
    if ! "$@" -resultBundlePath "$bundle" SWIFT_TREAT_WARNINGS_AS_ERRORS=YES >"$out" 2>&1; then
        grep -E 'error:|failed|FAIL' "$out" | tail -40
        fail "$name failed (log: $out)"
    fi
    local warnings
    warnings=$(xcrun xcresulttool get build-results --path "$bundle" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("status") != "succeeded" or d.get("errorCount", 0):
    sys.exit("build status %s, %s errors" % (d.get("status"), d.get("errorCount")))
print(d.get("warningCount", 0))
') || fail "$name: could not read build results"
    [ "$warnings" = "0" ] || fail "$name: $warnings warning(s)"
}

# Runs tests that were already built (warnings were checked then), failing on a nonzero exit.
xcodebuild_tests() {
    local name="$1"; shift
    local bundle="$WORK/$name.xcresult" out="$WORK/$name.log"
    rm -rf "$bundle"
    if ! "$@" -resultBundlePath "$bundle" >"$out" 2>&1; then
        grep -E 'error:|failed|FAIL' "$out" | tail -40
        fail "$name failed (log: $out)"
    fi
}
