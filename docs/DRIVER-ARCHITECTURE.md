# Building blocks of an NTFS driver, and what MacNTFS keeps

This note compares the structure of Microsoft's driver with the engine in this repository. It is based on the file layout and the import table of `ntfs.sys` (Windows 11 ARM, build 26100.4349) and on the public structure of Apple's FSKit modules (see [FSKIT-NOTES.md](FSKIT-NOTES.md)). No function was decompiled and no code is taken from any driver; the engine is written from the NTFS on-disk format and checked against images that independent implementations wrote.

## What `ntfs.sys` is made of (from its sections and imports)

- 3.3 MB, of which about 2 MB is pageable code (`PAGE` section) and 0.4 MB resident code (`.text`): a large driver, almost all of it rarely used paths.
- It imports 644 functions from the kernel and uses them in groups:
  - `Rtl`, `Ex`, `Ke`, `Ob`, `Ps`: runtime helpers, locks, memory, threads (about 270 imports).
  - `Fs`, `Io`: the file system interface of the I/O manager: opening, directories, queries, filter hooks (about 200).
  - `Cc` (39) and `Mm` (24): the cache manager and the memory manager. Windows does not read file data itself, it asks the cache.
  - `Se` (37) and the crypto and `ksecdd` imports: security descriptors (`$Secure`) and encryption (EFS).
  - `Clfs` (36) and `Tm` (18): the common log file service and the transaction manager: the journal (`$LogFile`) and transactional NTFS (`$TxfLog`).
  - `Ksr`, `Etw`, `Rpc`: kernel soft reboot, tracing, remote calls.

## What the code of `ntfs.sys` is spent on (Ghidra 12.2, no symbols)

Ghidra analysed the same file headless (no PDB was loaded, so function names are generic) and found 3,994 functions with 2.3 MB of code. Each function was sorted by the most telling kernel service it calls (priority: journal, transactions, encryption, security, cache, memory, file system runtime, I/O, executive, kernel, runtime):

| Calls mainly | Functions | Code |
| --- | --- | --- |
| Cache manager (`Cc`) | 461 | 658 KiB (29 %) |
| Executive: locks, pool, resources (`Ex`) | 1001 | 489 KiB (21 %) |
| Only internal calls, no kernel service | 1550 | 291 KiB (12 %) |
| File system runtime (`Fs`) | 251 | 198 KiB (8 %) |
| Journal (`Clfs`) | 88 | 174 KiB (7 %) |
| I/O manager (`Io`) | 182 | 127 KiB (5 %) |
| Memory manager (`Mm`) | 69 | 98 KiB (4 %) |
| Kernel (`Ke`) | 147 | 76 KiB (3 %) |
| Security (`Se`) | 57 | 59 KiB (2 %) |
| Runtime, other | 181 | 53 KiB (2 %) |
| Transactions (`Tm`) | 7 | 24 KiB (1 %) |

The median function is 200 bytes, 66 functions are larger than 4 KiB, the largest is 21 KiB. One internal function is called from 3,876 places (it is a helper for locking or error handling, not file system logic).

Read this as a rough picture, not as a measurement of "format code": a function that calls the cache and also parses a record counts as cache here, and a function without kernel calls can still be glue. It still shows the proportions. Only about an eighth of the code is free of kernel services, and the parts that can change a volume (journal, transactions, security, plus the cache and lock handling that serves them) are most of the rest. MacNTFS reads the format, which is the small part, and leaves the rest out on purpose.

## The same blocks in MacNTFS

| Block of a driver | In `ntfs.sys` | In MacNTFS |
| --- | --- | --- |
| Device access | I/O manager, volume manager | `BlockDevice` (read only by type), `FileBlockDevice` |
| On-disk format: boot sector, MFT records, fixups, attributes, runs, attribute lists | the core of the driver | `BootSector`, `Fixup`, `MFTRecord`, `Attribute`, `AttributeList`, `RunReader` |
| Directory indexes, name comparison | B-tree code, `$UpCase` | `DirectoryIndex`, `IndexEntry`, `NTFSName` |
| Data: compression, sparse, resident data, streams | `Mm`, `Cc`, compression | `CompressedRunReader`, `LZNT1`, `NTFSVolume.readData` |
| Links and reparse points | reparse filter framework | `LinkInfo` (read, never followed) |
| Volume state | dirty bit, `chkdsk` | `VolumeState` (dirty flag, hibernation, mount check) |
| Cache | cache manager | none yet; the name table per directory is the only cache |
| Journal and transactions | `Clfs`, `Tm`, `$LogFile` | not needed: the journal is not replayed, a dirty volume is reported |
| Security and EFS | `Se`, crypto | not read; EFS files are refused |
| Writing, allocation, repair | everything else | removed on purpose |

## What follows

1. A read-only engine needs about the first four rows. The large rest of a driver (journal, transactions, security, encryption, allocation) is exactly the part that can damage a volume, and it is not needed to read files.
2. To be better than a proprietary driver, MacNTFS does not need more features, it needs more evidence: every claim is a test against images written by ntfs-3g, the Linux kernel driver and Windows itself, and the parser is fuzzed.
3. The next block worth adding is a cache for data and records, because Windows leans heavily on its cache manager and a read-only engine over a USB disk will too. It must keep the read-only property (it only holds copies).

## Swift or Rust

Stay with Swift for `NTFSCore`:

- FSKit is a Swift and Objective-C API. A Rust core would need a C layer to reach FSKit, a second toolchain in CI, and contributors who know both. The gain would be small, because the engine already checks bounds, uses checked arithmetic and has no unsafe code in the parsers. Unsafe pointers appear in three small places only: reading from a device (`BlockDevice.swift`), the bulk copy of the `$UpCase` table (`NTFSName.swift`) and the list of mounts (`VolumeState.swift`).
- The parser, 79 tests, the corpus comparison and the fuzz harness exist in Swift. SwiftPM builds the library on Linux too (CI job `linux`), so it is not tied to the Mac.
- Rust would pay off for a `no_std` kernel or embedded use, or for a driver that must run in a place without Swift. That is not the goal of this project.

Revisit the decision if one of these happens: measured parse speed becomes the bottleneck (profile first), Swift on Linux or Windows becomes a requirement for users, or a contributor offers a Rust port of the parser that passes the same corpus. The corpus and the manifests are language neutral, which keeps that option open.
