# Status

Last updated: 2026-11-03. Maturity levels: **none** (not present), **refused** (detected and refused with an error, never read), **prototype** (works on the tested cases, known limits), **checked** (compared with an independent reference).

Evidence means a test in this repository. The reference for "checked" is the corpus in `Tests/Corpus` (20 images, written by ntfs-3g and, for two, by the Linux kernel driver ntfs3, manifests with SHA-256 hashes computed from the source content, cross-checked with ntfs-3g tools and The Sleuth Kit) and the committed images `Tests/Fixtures/mini.img` and `mini-attrlist.img`. No feature has been compared with an image written by Windows yet.

| Feature | Maturity | Evidence and limits |
|---|---|---|
| Boot sector and BPB | checked | Corpus: 512 and 4096-byte sectors, 512-byte to 64 KiB clusters. Hostile values are rejected (`ParserHardeningTests`). |
| MFT records and fixups | checked | Corpus. Fixups use 512-byte blocks on every volume. Mutation test with 3000 damaged images does not crash. |
| Data runs | checked | Corpus: fragmented and sparse files. Overflow is rejected. |
| Directory listing and lookup | checked | Corpus: nested directories, directory with 5000 files, Unicode names including NFC and NFD variants, case-insensitive lookup with the volume's `$UpCase` table (`LookupTests`), deleted entries not listed, hard links listed once per name. |
| File read (`cat`) | checked | Corpus: every file in 20 images reads back with the manifest hash. Reads beyond the initialized size return zeros. |
| Hard links | checked | Corpus `links`. |
| Sparse files | checked | Corpus `sparse`. |
| Interix symlinks (written by ntfs-3g as files) | checked | Corpus `links`. Readable as files and recognized by `readlink`. |
| Attribute list (`$ATTRIBUTE_LIST`) | checked | Corpus `attrlist`, `manydirs` and `mini-attrlist`: extension records are read and split attributes (hard-link names, index blocks, data runs) are merged. Damaged lists are reported as corrupt. A volume whose `$MFT` list points outside the known part of the MFT is refused. |
| Compressed files (LZNT1) | checked | Corpus `compressed`: text, random, all-zero and odd-sized files up to 1 MiB. Hand-computed LZNT1 vectors in `LZNT1Tests`. Damaged data is reported as corrupt. |
| Encrypted files | refused | Unit test. No corpus image. |
| Links: where they point (`readlink`) | checked | Corpus `links`: Windows file symlink, directory symlink and junction (substitute name, print name, flags), and Interix links written by ntfs-3g. WSL links are parsed but have no corpus image. |
| Link content and reparse points in general | refused | `cat` of a link and listing a junction stop with exit code 3. Links are never followed. |
| Named data streams (ADS) | checked | Corpus `ads`: resident and non-resident streams, a stream on a directory, a Unicode stream name, an empty stream. `macntfs streams` lists them, `cat --stream` reads one. |
| Deleted file recovery | none | Removed with the forensics code. |
| Hibernation and Fast Startup detection | checked | Corpus `hibernated` and `hiberfil-woken` (a `hiberfil.sys` with and without the `hibr` mark). Reported by `probe` and as a warning. |
| Dirty flag | prototype | Corpus `dirty`. The flag in that image was set by hand, because neither ntfs-3g nor ntfs3 leaves it set. |
| Journal replay | none | |
| Detection of a device mounted for writing | prototype | `MountCheck` on the list from `getmntinfo`, unit-tested with a synthetic list. Not tried with a real mounted NTFS device. |
| Windows-written images | none | |
| Coverage-guided fuzzing | none | A seeded mutation test exists. |
| Write, format, repair | removed | Removed in this version. See `docs/SAFETY.md` for the old releases. |
| FSKit driver, macOS app | removed | The FSKit adapter only probed and loaded a volume and never mounted one. |

How to move a row up: add a corpus image or a test that shows the behavior against an independent reference and update this table in the same change.
