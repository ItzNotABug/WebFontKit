#!/usr/bin/env bash
# Rebuilds the Google Fonts catalogue and compares it with the committed one. Fails when the
# committed file URLs stop working or Google's answers change shape; otherwise refreshes the
# file if its content changed. CI runs it twice a month (.github/workflows/reckon.yml).
#
#   scripts/reckon.sh [--summary FILE]
exec python3 "$(dirname "$0")/catalog.py" reckon "$@"
