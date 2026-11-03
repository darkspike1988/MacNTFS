#!/usr/bin/env bash
# Host entry point. Builds the NTFS reference corpus into Tests/Corpus/out/.
# Usage: scripts/corpus/build.sh [image-name ...]     (default: all images)
# Needs a running Docker daemon (e.g. `colima start`).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/Tests/Corpus/out"
IMAGE="macntfs-corpus:1"

docker info >/dev/null 2>&1 || { echo "error: docker daemon not reachable (try: colima start)" >&2; exit 1; }
mkdir -p "$out" "$repo/Tests/Fixtures"

docker build -q -t "$IMAGE" "$here" >/dev/null

# FUSE inside the container needs /dev/fuse and SYS_ADMIN; --privileged is the portable way on colima.
docker run --rm --privileged \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v macntfs-corpus-cache:/cache -v "$here":/corpus:ro -v "$out":/out -v "$repo/Tests/Fixtures":/fixtures \
  "$IMAGE" /corpus/build-in-container.sh "$@"
