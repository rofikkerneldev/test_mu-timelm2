#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo"
mode="${1:-DEBUG}"
case "$mode" in
  DEBUG|RELEASE) ;;
  *) printf 'Usage: %s [DEBUG|RELEASE]\n' "$0" >&2; exit 2 ;;
esac
python3 Resources/Scripts/prepare_timelm.py
python3 build_uefi.py -d timelm -r "$mode"
