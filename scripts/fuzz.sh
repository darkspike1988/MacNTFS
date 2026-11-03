#!/usr/bin/env bash
# Runs the coverage-guided fuzzer (libFuzzer with AddressSanitizer) against the engine.
# The fuzzer patches bytes in the boot sector, the first MFT records and the index blocks of a base image
# and then opens the volume, lists directories and reads files. Any crash or sanitizer report fails the run.
# Usage: scripts/fuzz.sh <image> [seconds]
# Needs a Linux Swift toolchain. On macOS run it in a container, for example:
#   docker run --rm -v "$PWD":/src:ro -w /src swift:5.10-jammy scripts/fuzz.sh Tests/Fixtures/mini.img 120
# A crash input is written to the current directory; reproduce it with: .build/debug/NTFSFuzz crash-<hash>
set -euo pipefail

image="${1:?usage: fuzz.sh <image> [seconds]}"
seconds="${2:-60}"
scratch="${FUZZ_SCRATCH:-/tmp/ntfs-fuzz-build}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift build --scratch-path "$scratch" --product NTFSFuzz -c release \
  -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library -Xswiftc -DFUZZING_ENGINE

mkdir -p "$work/corpus"
cd "$work"
# The base image stays allocated for the whole run on purpose, so leak detection is off.
ASAN_OPTIONS=detect_leaks=0 NTFS_FUZZ_BASE="$OLDPWD/$image" \
  "$scratch/release/NTFSFuzz" -max_total_time="$seconds" -max_len=2048 -print_final_stats=1 corpus
