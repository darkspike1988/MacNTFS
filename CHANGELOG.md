# Changelog

## Unreleased (planned as 0.3.0)

This version is a break. MacNTFS is now a read-only library and command line tool.

### Removed
- Writing files, formatting and "repair". Releases v0.1.3 to v0.2.2 could produce invalid NTFS data with them. See the [advisory](docs/advisories/2026-11-03-releases-up-to-0.2.2.md).
- The macOS app, the privileged helper, the FSKit adapter (it only probed a volume and never mounted one), the forensics helpers, and the DMG releases.

### Added
- `ReadOnlyFileSystem`: the operations a file system module needs (lookup by item ID, paged directory listing, reads, link targets), a bounded record cache, POSIX error mapping, and write operations that always return `EROFS`. Notes on an Apple-native app: `docs/APPLE-NATIVE.md`, `docs/FSKIT-NOTES.md`, `docs/DRIVER-ARCHITECTURE.md`.
- Twelve NTFS images written by Windows 11 (`ntfs.sys` in WinPE) with manifests, and `scripts/windows` that rebuilds them in a VMware Fusion VM without installing Windows. The engine reads all of them with the expected hashes.
- A coverage-guided fuzzer (`NTFSFuzz`, `scripts/fuzz.sh`) and a Linux CI job that builds the engine, runs the tests and fuzzes.

### Changed
- `macntfs` has the commands `probe`, `ls`, `cat`, `info`, `streams` and `readlink`. Errors go to standard error, `cat` streams large files, exit code 3 means "unsupported NTFS feature".
- `BlockDevice` has no write method. `FileBlockDevice` opens read-only and treats a short read as an error.
- Encrypted data and Windows reparse points are refused with `NTFSError.unsupported` instead of being returned as wrong bytes. Reads beyond the initialized size return zeros.
- Names are matched by exact UTF-16 first, then case-insensitively. Files whose names differ only in Unicode normalization are now separate files.

### Fixed
- Crashes on damaged or hostile images: overflow in boot sector, run list and block device arithmetic.
- Fixups on volumes with 4096-byte sectors (NTFS protects 512-byte blocks on every volume).
- Index blocks on volumes whose clusters are larger than an index block (for example 64 KiB clusters).
- A directory with thousands of files took over a minute to resolve a path. Lookup now stops at the first match.

### Added
- Warnings for a dirty volume and for Windows hibernation or Fast Startup. A device that is mounted for writing is refused (exit code 4, `--allow-mounted` overrides). `probe` shows the dirty flag, hibernation and mount state.
- `macntfs readlink` and `NTFSVolume.readLink(at:)`: the target of Windows symbolic links, junctions, WSL links and Interix links. Links are never followed.
- Case-insensitive name lookup uses the volume's `$UpCase` table.
- Compressed files (NTFS LZNT1 compression) are read. Checked against compressed files written by ntfs-3g.
- Two corpus images written by the Linux kernel driver `ntfs3`, a second NTFS implementation besides ntfs-3g.
- Named data streams (alternate data streams): `readFile(at:stream:)`, `dataStreams(at:)`, `macntfs streams` and `macntfs cat --stream`.
- Attribute lists (`$ATTRIBUTE_LIST`): large directories and files whose names, index blocks or data runs are split over extension records are read and merged. Checked against ntfs-3g images with directories of 5000 and 1500 entries.
- Reference corpus: 18 NTFS images with manifests (16 written by ntfs-3g, two by the Linux kernel driver ntfs3), cross-checked with ntfs-3g tools and The Sleuth Kit, and two committed test images.
- CI that builds the corpus in Linux, runs the tests on macOS, and checks that the release binary has no call that can change files.
- `docs/STATUS.md` with the maturity and evidence of each feature.
