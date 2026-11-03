# Status

Last updated: 2026-11-03. Maturity levels: **none** (not present), **refused** (detected and refused with an error, never read), **prototype** (works on the tested cases, known limits), **checked** (compared with an independent reference).

Evidence means a test in this repository. The reference for "checked" is the corpus in `Tests/Corpus` (13 images written by ntfs-3g, manifests with SHA-256 hashes computed from the source content, cross-checked with ntfs-3g tools and The Sleuth Kit) and the committed image `Tests/Fixtures/mini.img`. No feature has been compared with an image written by Windows yet.

| Feature | Maturity | Evidence and limits |
|---|---|---|
| Boot sector and BPB | checked | Corpus: 512 and 4096-byte sectors, 512-byte to 64 KiB clusters. Hostile values are rejected (`ParserHardeningTests`). |
| MFT records and fixups | checked | Corpus. Fixups use 512-byte blocks on every volume. Mutation test with 3000 damaged images does not crash. |
| Data runs | checked | Corpus: fragmented and sparse files. Overflow is rejected. |
| Directory listing and lookup | checked | Corpus: nested directories, directory with 5000 files, Unicode names including NFC and NFD variants, deleted entries not listed, hard links listed once per name. |
| File read (`cat`) | checked | Corpus: every file in 14 images reads back with the manifest hash. Reads beyond the initialized size return zeros. |
| Hard links | checked | Corpus `links`. |
| Sparse files | checked | Corpus `sparse`. |
| Interix symlinks (written by ntfs-3g as files) | prototype | Read as ordinary files. |
| Attribute list (`$ATTRIBUTE_LIST`) | checked | Corpus `attrlist`, `manydirs` and `mini-attrlist`: extension records are read and split attributes (hard-link names, index blocks, data runs) are merged. Damaged lists are reported as corrupt. A volume whose `$MFT` list points outside the known part of the MFT is refused. |
| Compressed files | refused | Corpus `compressed`. |
| Encrypted files | refused | Unit test. No corpus image. |
| Reparse points (symlinks, junctions) | refused | Corpus `links`. |
| Named data streams (ADS) | checked | Corpus `ads`: resident and non-resident streams, a stream on a directory, a Unicode stream name, an empty stream. `macntfs streams` lists them, `cat --stream` reads one. |
| Deleted file recovery | none | Removed with the forensics code. |
| Journal replay, hibernation detection | none | `probe` shows the dirty flag only. |
| Mounted-volume detection | none | |
| Windows-written images | none | |
| Coverage-guided fuzzing | none | A seeded mutation test exists. |
| Write, format, repair | removed | Removed in this version. See `docs/SAFETY.md` for the old releases. |
| FSKit driver, macOS app | removed | The FSKit adapter only probed and loaded a volume and never mounted one. |

How to move a row up: add a corpus image or a test that shows the behavior against an independent reference and update this table in the same change.
