#!/usr/bin/env bash
# Checks the read-only promise of the macntfs command line tool.
# Runs every command on a read-only copy of an image and fails if the image changes
# or if a command that would write exists.
# Usage: scripts/readonly-check.sh <macntfs-binary> <image>
# The commands use paths of Tests/Fixtures/mini.img (/many, /big.bin).
set -euo pipefail

bin="${1:?usage: readonly-check.sh <macntfs-binary> <image>}"
image="${2:?usage: readonly-check.sh <macntfs-binary> <image>}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$image" "$work/disk.img"
chmod 444 "$work/disk.img"

before="$(shasum -a 256 "$work/disk.img" | cut -d' ' -f1)"

"$bin" probe "$work/disk.img" >/dev/null
"$bin" ls "$work/disk.img" / >/dev/null
"$bin" ls "$work/disk.img" /many >/dev/null
"$bin" cat "$work/disk.img" /big.bin >/dev/null
"$bin" info "$work/disk.img" 5 >/dev/null

after="$(shasum -a 256 "$work/disk.img" | cut -d' ' -f1)"
if [ "$before" != "$after" ]; then
  echo "FAIL: the image changed ($before -> $after)" >&2
  exit 1
fi

for command in format write create-image repair check; do
  status=0
  "$bin" "$command" "$work/disk.img" >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 2 ]; then
    echo "FAIL: '$command' must be an unknown command (exit code 2), but exited with $status" >&2
    exit 1
  fi
done

echo "OK: read-only commands left the image unchanged and no write command exists"
