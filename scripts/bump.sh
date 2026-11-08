#!/usr/bin/env bash
# Bumps the patch of libraryVersion when it still matches the latest GitHub release, so main is
# bumped once per release however many changes land. Prints the new version, or nothing when main
# is already ahead. The weekly catalogue refresh runs it (.github/workflows/reckon.yml).
#
#   scripts/bump.sh
set -euo pipefail

file="$(dirname "$0")/../Sources/WebFontKit/Network/LibraryVersion.swift"
current=$(sed -n 's/^let libraryVersion = "\(.*\)"$/\1/p' "$file")
# No release yet is fine; a failed lookup must not drop a bump already in the refresh PR.
if ! released=$(gh release view --json tagName -q .tagName 2>&1); then
    [[ $released == *"release not found"* ]] && exit 0
    echo "$released" >&2
    exit 1
fi
[ -n "$current" ] && [ "$current" = "${released#v}" ] || exit 0

next="${current%.*}.$((${current##*.} + 1))"
sed "s/^let libraryVersion = \".*\"$/let libraryVersion = \"$next\"/" "$file" > "$file.tmp"
mv "$file.tmp" "$file"
echo "$next"
