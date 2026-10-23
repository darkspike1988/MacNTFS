# MacNTFS and Tuxera NTFS for Mac

Date: 23 October 2026. Compared against Tuxera NTFS for Mac 27.0.1 (`/Library/Filesystems/tuxera_ntfs.fs`) on macOS 27. Tuxera binaries were inspected with REA (Hopper provider) for interoperability; no Tuxera code, binary extract, or pseudocode is part of MacNTFS. All write experiments used disposable images.

## Architecture

| | Tuxera NTFS for Mac 27.0.1 | MacNTFS |
| --- | --- | --- |
| Kernel part | Loaded kext `com.tuxera.filesystems.tuxera_ntfs` 2023.5.23. Its strings name source paths under `macntfs-3g_package/subprojects/macfuse/core/fusefs/` (`fuse_vnops.c`, `fuse_ipc.c`, …): a renamed macFUSE kernel bridge. | None. FSKit user-space module (`com.apple.fskit.fsmodule`). |
| Engine | One user-space `tuxera_ntfs` process per mount, NTFS-3G lineage (`logfile.c`, `compress.c`, `ntfs_check_logfile`, `ntfs_empty_logfile`, `ntfs_jnl_reset_logfile`), plus a write-back block cache (`[CBCIO]`). | `NTFSCore` in Swift, running inside the FSKit extension, CLI and app. |
| Tools | `mkntfs`, `ntfsck`, `ntfslabel`, `ntfsls`, `ntfsdebug`, autorepair helper, menu bar agent. | `macntfs` CLI (probe, ls, cat, info, format, create-image, check, write) and the SwiftUI app. |
| Mounting status | Production. | Implemented; needs an Apple provisioning profile for the restricted FSKit entitlement before macOS will launch the module. |

A 1:1 copy of Tuxera is therefore neither possible nor desirable: it would require a kernel extension (Apple-signed kext entitlement, Reduced Security on Apple silicon) and proprietary code. MacNTFS reaches the same user-visible behavior through FSKit.

## Behavior comparison and findings

Evidence IDs refer to REA evidence recorded in this session.

| Behavior | Tuxera (REA / observed) | MacNTFS before | MacNTFS now |
| --- | --- | --- | --- |
| LZNT1-compressed files | Decompresses (`compress.c`). | Returned raw compressed bytes: silent corruption. | Decompresses per compression unit ([MS-XCA] LZNT1). Verified bit-identical against Tuxera. |
| Files with `$ATTRIBUTE_LIST` (heavily fragmented, large) | Reads. | `Out of bounds … available: 0`; such files could not be read. | Joins extents from extension records. Verified for file data; `$MFT` and directory indexes use the same resolver but have no fixture yet. |
| Bytes past initialized size | Zeros. | Stale disk contents. | Zeros. |
| EFS-encrypted files | Refused. | Returned ciphertext as if it were data. | Refused with an explanatory error. |
| `$LogFile` state | Checks (`ntfs_is_logfile_clean`), refuses or falls back to read-only ("unsafe state … no hibernation or fast restarting"), evidence `ev_0e1d9998…`. | Not checked; writes onto volumes Windows still had to replay. | Restart areas checked; writes refused on an unclean journal, Windows hibernation, dirty flag or `$MFT` extension records. FSKit mounts such volumes read-only. A clean journal is left untouched, which Tuxera's `ntfsck` accepts (an all-0xFF journal makes it reinitialize the log). |
| Write cost | Write-back cache, in-place writes. | Every write call read and rewrote the whole file, allocated new clusters for all of it, rewrote the entire `$Bitmap` (64 MiB on a 2 TB disk) with a rollback snapshot, and rebuilt the parent index. Copying 8 MiB in 64 KiB calls wrote ~0.5 GB (calculated). | In-place writes and appends; truncation only changes allocation. Only changed `$Bitmap` sectors are written. Appends reserve contiguous headroom, returned on close. The same 8 MiB copy writes less than 1.25 × the payload (test-enforced). |
| Directory entry sizes | Updated on close. | Rebuilt on every write. | Deferred while a file is open, synchronized on close, sync and unmount (FSKit open/close operations). |
| Free space (`statfs`) | Cached. | Full `$Bitmap` scan on every call. | Cached until the next change. |
| "Repair" | `ntfsck` with full metadata checks. | Copied the last sector over sector 0 whenever sector 0 was not NTFS (including FAT/exFAT partitions the app lists), and cleared the dirty flag only in `$MFT`, not `$MFTMirr`, without checking the journal. | Restores sector 0 only for a damaged NTFS boot sector with a backup at the exact NTFS position; clears the dirty flag only on a clean journal, in `$MFT` and `$MFTMirr` together. |

### A Tuxera defect found during this comparison

Writing a 300 000-byte all-zero file into a compressed directory through Tuxera returned zeros while mounted. After a clean eject and remount, Tuxera itself read 64 KiB of another file's text at its start, and Tuxera's `ntfsck` reported `Cluster accounting failed at 24266 - 24281 … 16 missing cluster in $Bitmap`. The file's first compression unit points at clusters that the volume bitmap marks free. MacNTFS reads the same bytes as Tuxera after remount; the defect is in the written volume.

## Validation performed

- `swift test`: 52 tests, 0 failures (1 skipped). New tests cover the Tuxera-written fixture (`Tests/NTFSCoreTests/Fixtures/tuxera-features.img.lzfse`: LZNT1 file and `$ATTRIBUTE_LIST` file, SHA-256 against Tuxera's own reads), LZNT1 edge cases, journal gating, append I/O volume, nearly full volumes, uninitialized ranges, repair safety, and a randomized stream workload on a Tuxera-`mkntfs` image followed by Tuxera `ntfsck -s -P` (exit 0, repeated six times).
- The randomized stream image was attached through the Tuxera kernel driver: all 12 files read identical to MacNTFS.
- `scripts/verify_tuxera_interop.py`: 134 files, Tuxera listing, Swift readback and full simulated check passed.
- The previously installed MacNTFS (21 October build) reads both fixture files incorrectly; the current build reads them correctly.

## Remaining gaps to Tuxera

- FSKit mounting requires a development or distribution provisioning profile authorizing `com.apple.developer.fskit.fsmodule`. Xcode currently has no Apple account configured on this Mac, so a profile cannot be created.
- Writing compressed, sparse or encrypted streams, files with extension records, hard links, extended attributes / named streams, and journal replay are not implemented. Such writes are refused rather than performed incorrectly.
- Directory index updates still rebuild the whole directory B-tree once per create, rename, remove and file close; very large directories write proportionally more.
- No Windows chkdsk validation has been performed yet.
