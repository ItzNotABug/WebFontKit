#!/usr/bin/env bash
# Rebuilds the Google Fonts catalogue and compares it with the committed one: refreshes it when
# Google's content changed or it is over 90 days old, and fails on dead URLs or a changed answer
# shape. CI runs it every Sunday (.github/workflows/reckon.yml).
#
#   scripts/reckon.sh [--summary FILE]
exec python3 "$(dirname "$0")/catalog.py" reckon "$@"
