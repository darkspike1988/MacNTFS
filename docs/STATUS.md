# Status

Last updated: 2026-11-03. Maturity levels: **none** (not present), **refused** (detected and refused with an error, never read), **prototype** (works on the tested cases, known limits), **checked** (compared with an independent reference).

Evidence means a test in this repository. The reference for "checked" is the corpus in `Tests/Corpus` (20 images, written by ntfs-3g and, for two, by the Linux kernel driver ntfs3, manifests with SHA-256 hashes computed from the source content, cross-checked with ntfs-3g tools and The Sleuth Kit) and the committed images `Tests/Fixtures/mini.img` and `mini-attrlist.img`. No feature has been compared with an image written by Windows yet.

| Feature | Maturity | Evidence and limits |
|---|---|---|
| Boot sector and BPB | checked | Corpus: 512 and 4096-byte sectors, 512-byte to 64 KiB clusters. Hostile values are rejected (`ParserHardeningTests`). |
| MFT records and fixups | checked | Corpus. Fixups use 512-byte blocks on every volume. Records marked `BAAD`, with a wrong number of update sequence entries or the wrong record number are rejected (`RecordChecksTests`, patched bytes of a real image). Corpus `basic-4kn` has 4096-byte sectors and 4096-byte MFT records (8 update sequence entries). Mutation test with 3000 damaged images does not crash. |
| Stale directory entries | checked | An index entry that points to a free record, an extension record or a record with another sequence number is not followed (`RecordChecksTests`). |
| Data runs | checked | Corpus: fragmented and sparse files. Overflow is rejected. |
| Directory listing and lookup | checked | Corpus: nested directories, directory with 5000 files, Unicode names including NFC and NFD variants, case-insensitive lookup with the volume's `$UpCase` table (`LookupTests`), deleted entries not listed, hard links listed once per name. |
| File read (`cat`) | checked | Corpus: every entry that a manifest labels `ok`, and every entry with an older `unsupported:attribute-list` or `unsupported:compression` label, must read back with the manifest hash in all 20 images, or the test fails (CI compares 18 of them, because the runner cannot load the `ntfs3` kernel module; the two kernel images are compared locally). Only entries labelled `unsupported:reparse` may be refused. Reads beyond the initialized size return zeros. |
| Hard links | checked | Corpus `links`. |
| Sparse files | checked | Corpus `sparse`. |
| Interix symlinks (written by ntfs-3g as files) | checked | Corpus `links`. Readable as files, `cat` returns the raw content, and `readlink` recognizes them (only for system files). |
| Attribute list (`$ATTRIBUTE_LIST`) | checked | Corpus `attrlist`, `manydirs`, `k-many` (written by the kernel driver) and `mini-attrlist` (the test fails if the engine refuses an entry that needs a list): extension records are read and split attributes (hard-link names, index blocks, data runs) are merged. Damaged lists are reported as corrupt (`ExtensionRecordTests`: wrong base reference, record not in use, entry pointing to an ordinary record, extents with a gap or missing end). A volume whose `$MFT` list points outside the known part of the MFT is refused. |
| Compressed files (LZNT1) | checked | Corpus `compressed`: text, random, all-zero and odd-sized files up to 1 MiB. Hand-computed LZNT1 vectors in `LZNT1Tests`, the three unit layouts and the error cases in `CompressedReaderTests`. Damaged data and content that the run list does not cover are reported as errors. Other compression formats are refused. |
| Encrypted files | refused | Unit test. No corpus image. |
| Links: where they point (`readlink`) | checked | Corpus `links`: Windows file symlink, directory symlink and junction (substitute name, print name, flags), and Interix links written by ntfs-3g. WSL links are parsed but have no corpus image. |
| Link content and reparse points in general | refused | `cat` of a link and listing a junction stop with exit code 3. Links are never followed. |
| Named data streams (ADS) | checked | Corpus `ads`: resident and non-resident streams, a stream on a directory, a Unicode stream name, an empty stream. `macntfs streams` lists them, `cat --stream` reads one. |
| Deleted file recovery | none | Removed with the forensics code. |
| Hibernation and Fast Startup detection | checked | Corpus `hibernated` and `hiberfil-woken` (a `hiberfil.sys` with and without the `hibr` mark). Reported by `probe` and as a warning. |
| Dirty flag | prototype | Corpus `dirty`. The flag in that image was set by hand, because neither ntfs-3g nor ntfs3 leaves it set. |
| Journal replay | none | |
| Lookup speed | prototype | The first lookup in a directory reads its whole index into a name table (up to 100,000 entries, 8 directories kept). Later lookups in it are dictionary lookups. Larger directories are scanned for each lookup. No B-tree descent. The table is a snapshot: a volume that changes while it is read is not followed. |
| Command line tool | checked | `CLITests` run the built binary: output, exit codes 1 to 3, standard error only for errors, warnings for a dirty volume and unreadable flags, unknown commands. Exit code 4 (mounted for writing) is not tested with a real mounted device. |
| Detection of a device mounted for writing | prototype | `MountCheck` on the list from `getmntinfo`, unit-tested with a synthetic list. Tried once by hand with a real device and a read-only mount (`hdiutil attach` of an image, mounted by FSKit): `probe` reported "read-only at /Volumes/MINI". Not tried with a writable mount, so exit code 4 is untested on a real device. |
| Windows-written images | none | |
| Coverage-guided fuzzing | prototype | `scripts/fuzz.sh` runs libFuzzer with AddressSanitizer on Linux against patched copies of `mini.img` and `mini-attrlist.img` (boot sector, first MFT records, index blocks); CI runs it for two minutes per image. By hand: 12,822 runs on `mini.img` and 1,251 on `mini-attrlist.img` (300 s each) and 5,208 more, no crash. That is a short campaign, not a long one. A seeded mutation test also runs in `swift test`. |
| Linux | checked | The library, the tool and all tests except the corpus comparison build and pass on Linux (CI job `linux`, Swift 5.10). |
| Write, format, repair | removed | Removed in this version. See `docs/SAFETY.md` for the old releases. |
| FSKit driver, macOS app | removed | The FSKit adapter only probed and loaded a volume and never mounted one. |

How to move a row up: add a corpus image or a test that shows the behavior against an independent reference and update this table in the same change.
