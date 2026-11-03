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

# k-* images are written by the Linux kernel driver ntfs3. The VM kernel may ship it as a module
# that is not installed; then fetch linux-modules-extra for exactly this kernel and insmod it
# (in-memory only, gone after a VM reboot). If that fails, corpus.py reports k-* as SKIPPED.
want_kernel=0
if [ "$#" -eq 0 ]; then want_kernel=1; fi
for a in "$@"; do case "$a" in k-*) want_kernel=1;; esac; done
if [ "$want_kernel" = 1 ] && ! grep -qw ntfs3 /proc/filesystems; then
  modprobe ntfs3 2>/dev/null || true
  if ! grep -qw ntfs3 /proc/filesystems; then
    echo "ntfs3 not loaded; trying linux-modules-extra-$(uname -r)"
    (
      set -e
      mkdir -p /cache /tmp/km && cd /cache
      if ! ls linux-modules-extra-"$(uname -r)"_*.deb >/dev/null 2>&1; then
        apt-get update -qq >/dev/null
        for i in 1 2 3 4 5; do apt-get download "linux-modules-extra-$(uname -r)" && break || sleep 3; done
      fi
      dpkg-deb -x linux-modules-extra-"$(uname -r)"_*.deb /tmp/km
      zstd -d -q -f /tmp/km/lib/modules/"$(uname -r)"/kernel/fs/ntfs3/ntfs3.ko.zst -o /tmp/ntfs3.ko
      insmod /tmp/ntfs3.ko
    ) >/dev/null 2>&1 || echo "WARNING: could not load the ntfs3 kernel module; k-* images will be skipped" >&2
  fi
fi

python3 -I "$here/corpus.py" "$@"

if [ -n "${HOST_UID:-}" ]; then
  chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$CORPUS_OUT"
fi
rm -rf "${CORPUS_WORK:?}"/*
echo "done: $(du -sh --apparent-size "$CORPUS_OUT" | cut -f1) apparent, $(du -sh "$CORPUS_OUT" | cut -f1) on disk"
