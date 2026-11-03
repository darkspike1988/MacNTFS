# MacNTFS

> **Experimental, read-only NTFS inspector written in Swift.**
> Not a driver. Do not use it to write to disks you care about.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Status

MacNTFS is an early prototype. It can read parts of an NTFS volume from a disk image or device and show what it finds. It does **not** mount NTFS volumes, and it does **not** add write support to macOS.

- **Writing, formatting and repairing are locked.** Earlier releases offered them. Code review found that they produce NTFS structures Windows may reject. See [docs/SAFETY.md](docs/SAFETY.md).
- **If you used a release up to v0.2.2 to write to a volume:** back up the data, then check the volume in Windows. See the [advisory](docs/advisories/2026-11-03-releases-up-to-0.2.2.md).
- The test suite uses small in-memory images produced by this project itself. Nothing has been validated against Windows `chkdsk` yet.
- Feature by feature status: [docs/STATUS.md](docs/STATUS.md).

## What it can do today

Read-only, on images and block devices:

- Parse the boot sector and MFT records and list directories.
- Read simple files. Compressed, encrypted and attribute-list files and reparse points are not handled reliably yet and may return wrong data instead of an error. This is a known defect.
- Experimental forensics helpers (scan for deleted records, hex dump). Not validated.

## What it is not

- It is **not** an FSKit driver. The FSKit adapter in `Sources/NTFSCore/FSKitAdapter.swift` only probes and loads a volume. There is no file system extension target, so nothing is mounted through it.
- It is **not** a replacement for Paragon NTFS or Tuxera NTFS.

## Need to write to NTFS on a Mac?

Other free, open-source projects build FSKit drivers for this (listed as of 2026-11-03, based on their own descriptions, **not reviewed or tested by this project**): [ntfstool/ntfstool](https://github.com/ntfstool/ntfstool), [dr-kbadawi/ttntfs](https://github.com/dr-kbadawi/ttntfs), [HuanchuanTech/xntfs](https://github.com/HuanchuanTech/xntfs). FSKit modules need a signature backed by an Apple Developer account, so use their signed builds.

## Build and try (read-only)

Requires macOS 14 or later and Swift 5.10 or later.

```bash
git clone https://github.com/darkspike1988/MacNTFS.git
cd MacNTFS
swift build -c release
swift test

# Inspect an image or, with root, a raw device you are sure is not mounted writable
.build/release/macntfs probe disk.img
.build/release/macntfs ls disk.img /
.build/release/macntfs cat disk.img /path/to/file > out.bin
```

Raw devices (`/dev/rdiskN`) need root. Reading a volume that another driver has mounted writable can return inconsistent data. Make an image first (`sudo dd if=/dev/rdiskN of=disk.img bs=1m`) and inspect the copy.

## Where this is going

The plan under discussion is a small, well-tested, read-only Swift library with a command line tool, checked against independent references. The write, format and repair code is scheduled to be removed from the repository. See [concepts_brief.md](concepts_brief.md).

## Contributing and reporting problems

Issues are welcome. Include the macOS version, the command you ran, and the output. Do not attach disk images that contain private data.

## License

[MIT](LICENSE).
