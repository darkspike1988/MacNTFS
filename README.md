# MacNTFS

> **A read-only NTFS inspector and Swift library for macOS.**
> It reads NTFS disk images and devices. It does not write, and it is not a driver.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Status

Early, but checked: the engine is compared with reference images written by ntfs-3g (see [Testing](#testing)). It is still a prototype with known limits, listed below and in [docs/STATUS.md](docs/STATUS.md).

- **It cannot write.** The code has no write path at all. Disks are opened read-only, and CI checks that the command line tool contains no call that can change a file.
- **It refuses instead of guessing.** Encrypted and link data is not read. The tool stops with exit code 3 and does not return wrong bytes.
- **If you used a release from v0.1.3 to v0.2.2 to write to a volume:** those releases could produce invalid NTFS data. Back up your files and check the volume in Windows. See the [advisory](docs/advisories/2026-11-03-releases-up-to-0.2.2.md).

## Use it

Requires macOS 14 or later and Swift 5.10 or later.

```bash
git clone https://github.com/darkspike1988/MacNTFS.git
cd MacNTFS
swift build -c release

.build/release/macntfs probe disk.img                 # boot sector and volume information
.build/release/macntfs ls disk.img /Documents         # list a directory
.build/release/macntfs cat disk.img /Documents/a.txt > a.txt
.build/release/macntfs info disk.img 5                # one MFT record and its attributes
.build/release/macntfs streams disk.img /a.txt        # default and named data streams
.build/release/macntfs cat disk.img /a.txt --stream name   # one named data stream
.build/release/macntfs readlink disk.img /link         # where a link points
```

Exit codes: `0` success, `1` error, `2` wrong usage, `3` the data uses an NTFS feature that is not supported, `4` the device is mounted for writing.

**Devices.** `/dev/rdiskN` needs root. A device that another driver has mounted for writing is refused (exit code 4), because its contents can change while you read them; `--allow-mounted` overrides that. `probe` shows the dirty flag, the hibernation state and the mount state. The other commands print a warning on standard error for a volume that is not clean (dirty flag) or that Windows hibernated (Fast Startup), or when they cannot tell. Make an image first and inspect the copy:

```bash
sudo dd if=/dev/rdisk4s1 of=disk.img bs=1m
```

**As a library.**

```swift
import NTFSCore

let volume = try NTFSVolume(blockDevice: try FileBlockDevice(path: "disk.img"))   // read-only
for item in try volume.listDirectory(at: "/") {
    print(item.name, item.fileSize)
}
let data = try volume.readFile(at: "/hello.txt")
```

`BlockDevice` has no write method, so code that takes a device cannot modify the disk. Add the package with `.package(url: "https://github.com/darkspike1988/MacNTFS.git", branch: "main")` and the product `NTFSCore`. The API is not stable yet.

## Known limits

- Encrypted files (EFS) are refused. Windows symbolic links, junctions and other reparse points are not followed, their content is not read, and a directory link is not listed. `macntfs readlink` shows where a link points. Links in the Interix format, which ntfs-3g writes, are ordinary small files; `readlink` recognizes them, and `cat` returns their raw content.
- A volume whose `$MFT` has an attribute list that points outside the part of the MFT known from record 0 is refused.
- Names are matched by exact UTF-16 first, then ignoring case with the volume's `$UpCase` table. Unicode is not normalized, as in NTFS.
- The journal is not replayed. A volume that Windows did not shut down cleanly or hibernated can show outdated data. `probe` and the other commands report the dirty flag and Windows hibernation (Fast Startup), but they read the volume as it is.
- The engine has been compared with images written by ntfs-3g, by the Linux kernel driver ntfs3 and by Windows 11 (in WinPE, with 4 KiB to 64 KiB clusters). Volumes of a long-running Windows system, with 512-byte clusters, EFS or deduplication, have not been checked.

## Need to write to NTFS on a Mac?

Other free, open-source projects build FSKit drivers for this (listed as of 2026-11-03, based on their own descriptions, **not reviewed or tested by this project**): [ntfstool/ntfstool](https://github.com/ntfstool/ntfstool), [dr-kbadawi/ttntfs](https://github.com/dr-kbadawi/ttntfs), [HuanchuanTech/xntfs](https://github.com/HuanchuanTech/xntfs). FSKit modules need a signature backed by an Apple Developer account, so use their signed builds.

## Testing

```bash
swift test                          # unit tests, hostile-input tests, mutation test, committed fixture
scripts/readonly-check.sh .build/debug/macntfs Tests/Fixtures/mini.img
```

The engine builds and passes its tests on Linux as well. A coverage-guided fuzzer (libFuzzer with AddressSanitizer) opens patched copies of an image; it needs a Linux Swift toolchain, on a Mac for example in a container:

```bash
docker run --rm -v "$PWD":/src:ro -w /src swift:5.10-jammy scripts/fuzz.sh Tests/Fixtures/mini.img 120
```

`swift test` also runs the command line tool (exit codes, channels, warnings) against the committed image. The strongest check compares the engine with reference images. `scripts/corpus/build.sh` writes 18 NTFS images in a Linux container, 16 with ntfs-3g and two with the Linux kernel driver ntfs3, and two more images are committed in `Tests/Fixtures` (512 and 4096-byte sectors, clusters from 512 bytes to 64 KiB, fragmented, sparse, compressed, links, a directory with 5000 files, files with attribute lists, compressed files, deleted files and more) together with manifests of paths, sizes and SHA-256 hashes computed from the source content. `scripts/corpus/verify.sh` cross-checks each manifest with ntfs-3g and The Sleuth Kit. `swift test` then requires that every file reads back with the same hash or is refused with the expected error. Wrong bytes without an error fail the test. Details: [Tests/Corpus/README.md](Tests/Corpus/README.md). Building the corpus needs Docker (on macOS for example `colima start`).

## Where this is going

A small, well-tested, read-only library, checked against independent references. See [concepts_brief.md](concepts_brief.md) for the plan and [docs/STATUS.md](docs/STATUS.md) for what works.

## Contributing and reporting problems

Issues are welcome. Include the macOS version, the command you ran, and the output. Do not attach disk images that contain private data.

## License

[MIT](LICENSE).
