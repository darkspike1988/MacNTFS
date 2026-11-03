#!/usr/bin/env bash
# Cross-checks every Tests/Corpus/out/*.manifest.json against its image with ntfscat/ntfsls
# (ntfs-3g) and ifind/icat/fls/istat (The Sleuth Kit). Prints a table; exits non-zero on any mismatch.
# Usage: scripts/corpus/verify.sh [image-name ...]
# Runs inside the container; when started on the host it re-launches itself through Docker.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f /.dockerenv ] && [ -z "${CORPUS_IN_CONTAINER:-}" ]; then
  repo="$(cd "$here/../.." && pwd)"
  docker info >/dev/null 2>&1 || { echo "error: docker daemon not reachable (try: colima start)" >&2; exit 1; }
  docker build -q -t macntfs-corpus:1 "$here" >/dev/null
  exec docker run --rm --privileged -e CORPUS_IN_CONTAINER=1 \
    -v "$here":/corpus:ro -v "$repo/Tests/Corpus/out":/out:ro -v "$repo/Tests/Fixtures":/fixtures:ro \
    macntfs-corpus:1 /corpus/verify.sh "$@"
fi

export LC_ALL=C.UTF-8 PYTHONUTF8=1
echo "ntfs-3g: $(ntfs-3g --version 2>&1 | head -1)"
echo "TSK    : $(fls -V 2>&1 | head -1)"
exec python3 -I "$here/verify.py" "${CORPUS_DIR:-/out}" "$@"
