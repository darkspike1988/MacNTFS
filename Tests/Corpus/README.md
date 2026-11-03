# NTFS reference corpus

Reproducible NTFS images plus a manifest per image, used to check `NTFSCore`
against an independent reference. Nothing under `Tests/Corpus/out/` is committed
(it is git-ignored); the scripts in `scripts/corpus/` regenerate it.

## Where the truth comes from

The manifest (paths, sizes, SHA-256) is computed from the **source bytes** that a
seeded PRNG produces, **before** they are written into the image. The image is
never read back with the tool that wrote it to produce a hash. As a second step,
`verify.sh` reads every image with two other readers and compares against the
manifest:

* ntfs-3g tools: `ntfscat` (content, named streams), `ntfsls` (directory listings)
* The Sleuth Kit: `ifind -n` + `icat` (content), `fls -r` (whole tree and stream
  inodes), `istat` (checks that an `expect` label is really true, e.g. that an
  entry marked `unsupported:attribute-list` has an `$ATTRIBUTE_LIST`)

A disagreement means the manifest or the image is wrong. It is never hidden.

## Build and verify

Needs a Docker daemon (on macOS: `colima start`). No other host dependency.

```sh
scripts/corpus/build.sh            # all images -> Tests/Corpus/out/<name>.img + <name>.manifest.json
scripts/corpus/build.sh sparse ads # only some images
scripts/corpus/verify.sh           # cross-check everything, prints a table, non-zero exit on mismatch
scripts/corpus/verify.sh links     # only some images
```

* `build.sh` builds the `macntfs-corpus:1` image (`ubuntu:24.04` + `ntfs-3g`,
  `sleuthkit`, `python3`, `attr`) from `scripts/corpus/Dockerfile`, then runs
  `build-in-container.sh` (which runs `corpus.py`) in a `--privileged` container.
  Writing directories, streams, sparse files and reparse points needs a FUSE
  mount of the image, which is why the container is privileged.
* Rebuilding is idempotent: it replaces `out/` contents. About 5 seconds for
  build, about 2 minutes for verify (the `manydirs` image dominates).
* Disk use: about 400 MB apparent, images are sparse where the host file system
  allows it.

## Reproducibility, and its limit

File **content and manifests are stable**: every file is derived from
`sha256("macntfs-corpus:1:<image>:<key>")`, so the same hashes come out on every
build and the manifests are byte-identical between builds. The **images
themselves are not bit-reproducible**: `mkntfs` randomizes the volume serial
number and `ntfs-3g` stamps current timestamps. Do not compare image hashes.
Compare against the manifest.

## Manifest schema (version 1)

```json
{
 "schema": 1,
 "image": "basic-512.img",
 "tool": "ntfs-3g 2022.10.3",
 "sectorSize": 512,
 "clusterSize": 4096,
 "volumeLabel": "CORPUS-BASIC512",
 "entries": [
  {"path": "/dir/file.txt", "type": "file", "size": 123, "sha256": "...", "expect": "ok",
   "linkTarget": null, "streams": [{"name": "s1", "size": 1, "sha256": "..."}]}
 ]
}
```

The file is JSON with ASCII escapes (`́` etc.), so NFC and NFD names survive
any editor. Entries are sorted by path; one entry per line.

| Field | Meaning |
|---|---|
| `path` | Absolute path inside the volume, `/` separated, UTF-8 after decoding. Names are compared byte-exact; no Unicode normalization is applied (NFC and NFD names are different files). |
| `type` | `file`, `dir`, `symlink`, `hardlink`, `deleted`. |
| `size` | Logical size of the default data stream in bytes. `null` for directories and for reparse points that have no data. |
| `sha256` | Hex SHA-256 of the full logical content of the default stream (holes read as zeros). `null` for directories and reparse points. |
| `expect` | What a minimal read-only engine SHOULD do, see below. |
| `linkTarget` | `symlink`: the link target as recorded. `hardlink`: the first path of the hardlink group (the same inode); every path of the group has its own entry. Otherwise `null`. |
| `streams` | Alternate (named) data streams: `name`, `size`, `sha256`. Empty list if none. Directories may carry streams too. |
| `note` | Optional free text explaining an unusual entry. |

`expect` values:

* `ok`: the default data stream must read back byte-identical (size and SHA-256).
  For a directory: it must be listable and its listing must equal the set of
  non-deleted children in the manifest.
* `unsupported:compression`: data is stored NTFS-compressed (LZNT1). A clear error
  is acceptable; silently wrong bytes are not (correct bytes are of course fine).
* `unsupported:attribute-list`: the file's MFT record has an `$ATTRIBUTE_LIST`
  (attributes or runlist continue in extension records).
* `unsupported:reparse`: the entry is a reparse point (symlink/junction). A clear
  error is acceptable; reading it as a normal file or directory is not.
* `absent`: used only with `type: "deleted"`. The path must **not** appear in any
  directory listing and must not resolve. `size`/`sha256` describe the content
  that was deleted and are informational only.

The `unsupported:attribute-list` label is derived from the oracle, not guessed: after each build, TSK `istat` is run on the base MFT record of every entry and of every ancestor directory, and any entry with an `$ATTRIBUTE_LIST` on that path (including directories and everything below them) gets the label; `verify.sh` enforces it in both directions.

Hardlinks: all paths have the same content; `expect` is the same for each path.

## Images

| Image | Geometry | Covers | Entries |
|---|---|---|---|
| `basic-512` | 512 B sectors, 4 KiB clusters, 32 MiB | Nested dirs (5 levels), empty file, 1 B, 500 B, 700 B (around the resident/non-resident boundary), 4096 B, 4097 B, 100 KiB, 5 MiB; Unicode names (NFC vs NFD `café.txt`, CJK, Cyrillic, Hebrew, non-BMP emoji, which needs a UTF-16 surrogate pair); a 255-character name and an 85-character CJK name (255 UTF-8 bytes); spaces, leading dots, DOS-looking names (`LONGFI~1.TXT`, `tilde~1.txt`) | 47 |
| `basic-4kn` | **4096 B sectors**, 4 KiB clusters | Same content as `basic-512`; boot-sector/MFT-record maths with a 4 KiB sector | 47 |
| `cluster-512` | 512 B sectors, **512 B clusters** | Same content; smaller clusters than MFT-record-related sizes, long runlists | 47 |
| `cluster-64k` | 512 B sectors, **64 KiB clusters** | Same content; large clusters, tail slack | 47 |
| `fragmented` | 4 KiB clusters | Files from interleaved appends of 16 writers, then deletions and refills: runlists with dozens of runs (verified: each file has at least 3 runs) | 16 |
| `sparse` | 4 KiB clusters | Sparse files: hole at start, in the middle, entirely a hole, hole then a tail, 40 random scattered chunks over 16 MiB, unaligned data offsets, `initialized_size < size`. The hash covers the whole logical content. | 7 |
| `compressed` | 4 KiB clusters | Files in a directory with the compressed flag (data attribute `Compressed`, LZNT1): compressible text, a 64 KiB repeating pattern, incompressible random data, half zeros, odd sizes. `expect: unsupported:compression`. `/plain/` holds uncompressed controls with `expect: ok`. | 11 |
| `ads` | 4 KiB clusters | Alternate data streams: resident and non-resident, empty default stream with a named stream, empty named stream, Unicode stream name, stream on a directory, a 60 KB stream | 9 |
| `links` | 4 KiB clusters | Hard links (4 paths to one non-resident inode, 2 to a resident one); ntfs-3g **Interix** symlinks (a SYSTEM file with an `IntxLNK` payload; relative, parent, absolute, dangling) with `expect: ok` on the raw payload; real **reparse points** crafted via `system.ntfs_reparse_data`: `IO_REPARSE_TAG_SYMLINK` on a file and a directory, and an `IO_REPARSE_TAG_MOUNT_POINT` junction, `expect: unsupported:reparse` | 18 |
| `manydirs` | 4 KiB clusters | `/big` with 3500 files and a subdirectory with 1500 longer-named files, so both need `$INDEX_ALLOCATION` blocks (verified via `istat`); a third level; 300 directories under `/dirs` | 5629 |
| `attrlist` | 4 KiB clusters | `$ATTRIBUTE_LIST`: one inode with 80 long hard-link names, three files with ~800 runs each (runlist overflows the base record), a file with 40 alternate streams. All `expect: unsupported:attribute-list`; `/al/plain.txt` is a control without one | 88 |
| `deleted` | 4 KiB clusters | Files, a directory tree and a name that was reused after deletion. `type: deleted` entries must not show up in listings. | 18 |
| `empty` | 8 MiB, fresh `mkntfs`, never mounted | Only system files; root must list as empty | 0 |

Volume labels are `CORPUS-<NAME>` with dashes removed.

## What is NOT covered

* **No Windows-written image.** This corpus was written by `ntfs-3g`, so it is
  **less independent than a Windows-made one**: Windows and ntfs-3g can differ in
  how they lay out and tag structures (DOS 8.3 names, `$Secure`/security IDs,
  `$UsnJrnl`, `$LogFile` state, index layout and fixups, timestamps, compression
  chunking, resident/non-resident thresholds), and a misreading shared by
  ntfs-3g, TSK and `NTFSCore` would not be caught here. The content hashes
  themselves are still independent of every reader, because they come from the
  source data.
* ntfs-3g is also the second reader in `verify.sh`. The Sleuth Kit is a separate
  code base, which is what gives that check its value, but both are open-source
  readers of the same format.
* Volumes the OS considers dirty or with an unreplayed `$LogFile`, hibernation or
  Fast Startup state, BitLocker, `$EFS`.
* Other reparse tags (WOF/WIMBoot, OneDrive placeholders, dedup, AppExecLink), on-disk
  DOS-name namespaces generated by Windows, `$Secure` ACL variety, `$Extend` objects
  (`$UsnJrnl`, `$Quota`, `$ObjId`) beyond what mkntfs creates, `$BadClus` content.
* Compression with cluster sizes above 4 KiB (NTFS cannot do it), and compression
  of attributes other than the unnamed `$DATA`.
* `deleted`: ntfs-3g clears most metadata of a deleted file or reuses its record,
  so mostly the images test that deleted names are **absent** from listings. A few
  not-in-use MFT records remain (TSK reports them under `$OrphanFiles`).
  Directory-index slack, and orphaned-but-recoverable names, are not modelled.
* Volumes much larger than 128 MiB, 2^32+ clusters, MFT with more than one data run
  of its own beyond what the largest image produces, multi-run `$MFT` growth.
* Symlinks written by Linux are Interix-style; there are no `IO_REPARSE_TAG_LX_SYMLINK`
  (WSL) links.

## Files

* `scripts/corpus/build.sh` – host entry point
* `scripts/corpus/build-in-container.sh` – runs in the container, calls `corpus.py`
* `scripts/corpus/corpus.py` – image builders, seeded content, manifest writer
* `scripts/corpus/verify.sh`, `verify.py` – cross-check with `ntfscat`/`ntfsls`/TSK
* `scripts/corpus/Dockerfile` – `ubuntu:24.04` with the tools

`Tests/Fixtures/mini.img` + `mini.manifest.json` (built only by `scripts/corpus/build.sh mini`, verified by `verify.sh mini`) is a 10 MiB ntfs-3g image for the Swift unit tests so they need no project-written image; unlike `out/`, it is committed on purpose.
