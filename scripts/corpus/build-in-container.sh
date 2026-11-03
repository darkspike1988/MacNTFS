#!/usr/bin/env bash
# Runs INSIDE the container. Builds the images into $CORPUS_OUT (default /out).
# Usage: build-in-container.sh [image-name ...]
set -euo pipefail
export LC_ALL=C.UTF-8 PYTHONUTF8=1
export CORPUS_WORK="${CORPUS_WORK:-/work}" CORPUS_OUT="${CORPUS_OUT:-/out}"
here="$(cd "$(dirname "$0")" && pwd)"

[ -e /dev/fuse ] || { echo "error: /dev/fuse missing; run the container with --privileged" >&2; exit 2; }

mkdir -p "$CORPUS_WORK" "$CORPUS_OUT"
rm -rf "${CORPUS_WORK:?}"/*

echo "ntfs-3g: $(ntfs-3g --version 2>&1 | head -1)"
echo "mkntfs : $(mkntfs --version 2>&1 | grep -m1 mkntfs)"
echo "TSK    : $(fls -V 2>&1 | head -1)"

python3 -I "$here/corpus.py" "$@"

if [ -n "${HOST_UID:-}" ]; then
  chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$CORPUS_OUT"
fi
rm -rf "${CORPUS_WORK:?}"/*
echo "done: $(du -sh --apparent-size "$CORPUS_OUT" | cut -f1) apparent, $(du -sh "$CORPUS_OUT" | cut -f1) on disk"
