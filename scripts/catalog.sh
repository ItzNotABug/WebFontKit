#!/usr/bin/env bash
# Rebuilds the bundled Google Fonts catalogue: every family's version and the file ID of each
# style, so a first load can skip the CSS2 lookup. Run it before a release.
#
#   scripts/catalog.sh                       fetch from Google; write the bundled file and
#                                            Tests/Fixtures/catalog/shipped.tsv, its family listing
#   scripts/catalog.sh --rows rows.json OUT  build only OUT from saved rows (offline; tests)
exec python3 "$(dirname "$0")/catalog.py" build "$@"
