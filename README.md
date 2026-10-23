# MacNTFS

An open source NTFS toolkit for macOS, written in Swift. MacNTFS combines a SwiftUI drive management app, a command line tool, and the reusable `NTFSCore` library.

**Development status:** native NTFS formatting and offline file operations are implemented and tested on disk images and a designated 8 GB USB stick. The FSKit volume implementation and extension bundle are present; mounting through MacNTFS itself is awaiting provisioned runtime validation. Use disposable media for write and format experiments.

## Features

| Component | Current behavior |
| --- | --- |
| macOS app | Discovers drives, displays volume information, browses files, and imports files into the selected directory. |
| NTFS reader | Parses boot sectors, MFT records, attributes, directories, and file data, including LZNT1-compressed files, sparse files, files whose attributes span extension records (`$ATTRIBUTE_LIST`), and uninitialized ranges. EFS-encrypted files are refused. |
| Offline writer | Creates files and directories, writes and appends in place, truncates, renames and removes entries, updates only the changed allocation bitmap sectors, grows MFT and directory indexes, and handles fragmented allocation. Writes are refused while Windows is hibernated, the volume is dirty, or the NTFS journal is unclean; FSKit then mounts read-only. |
| Native formatter | Creates NTFS 3.1 metadata, including system streams, indexes, allocation maps, and a clean log. |
| Inspection tools | Provides metadata inspection, limited consistency checks, hexadecimal inspection, and recovery tools. |
| Finder integration | FSKit volume operations and extension bundle are implemented; independent mounting is not yet verified. |

App imports into an already mounted volume use the filesystem driver that mounted it. Successful copying through that route does not demonstrate MacNTFS's own filesystem mounting support.

## Requirements

- macOS 14 or later for the app and CLI.
- Swift 5.10 or later and a compatible macOS SDK to build from source.
- FSKit development requires a compatible SDK and macOS 15.4 or later.

## Build and run

```sh
git clone https://github.com/darkspike1988/MacNTFS.git
cd MacNTFS
swift build
swift test
swift run MacNTFSApp
```

Create a release build with `swift build -c release`. The packaging script creates an app bundle containing the matching `macntfs` helper and a DMG:

```sh
./scripts/build_dmg.sh 0.3.0-dev
```

The script produces a development package in `build/dist/` with the matching helper and FSKit extension. It uses ad-hoc signing by default. A mountable extension requires an Apple-issued signing identity and a provisioning profile authorizing its bundle identifier and FSKit entitlement:

```sh
MACNTFS_SIGNING_IDENTITY='Apple Development: …' \
MACNTFS_FSKIT_PROFILE=/path/to/extension.provisionprofile \
./scripts/build_dmg.sh 0.3.0-dev
```

Without that profile, the bundled extension is for build and registration checks only. Development signing does not provide notarization. See the [release checklist](docs/RELEASE_CHECKLIST.md) before distributing a build.

## Command line examples

These commands operate on an NTFS partition image, rather than an image containing a partition table.

```sh
.build/debug/macntfs create-image test.img 64 TEST
.build/debug/macntfs probe test.img
.build/debug/macntfs ls test.img /
.build/debug/macntfs write test.img source.txt destination.txt /
.build/debug/macntfs cat test.img /destination.txt
.build/debug/macntfs check test.img
```

Run `.build/debug/macntfs --help` for the complete command list. `probe` also reports the journal state and whether writing is allowed. Raw access requires appropriate device permissions and an unmounted volume.

## Validation

On 23 October 2026, three native format/write/read cycles passed on a designated 8 GB Kingston USB stick with 1, 4, and 64 KiB clusters. Each cycle verified 67 files by SHA-256 both through the offline engine and through an independently mounted filesystem. These results validate on-disk interoperability; they do not verify mounting through MacNTFS. See the [USB test report](docs/validation/usb-native-20261023.json).

See the [comparison with Tuxera NTFS for Mac](docs/TUXERA_COMPARISON.md) for the reverse-engineering findings and interoperability tests.

## Current limitations

- Physical formatting is experimental. Windows interoperability and production readiness have not been verified.
- The FSKit extension still needs a provisioning profile and successful runtime mount, Finder, eject, and reconnect tests.
- Synchronous write rollback does not provide journal replay or crash recovery.
- Raw writes currently support 512-byte sectors and 1024-byte MFT records. Unsupported writable metadata, including attribute extension records and compressed or encrypted data, is rejected.
- CLI and app imports still buffer whole files. Directory indexes are rebuilt once per create, rename, remove, and file close, so very large directories cost more. No performance advantage over Tuxera is claimed.
- Writing compressed, sparse, or encrypted streams, files with extension records or several hard links, and named streams is refused. There is no journal replay.
- The app has no installed privileged XPC service. Privileged raw operations currently depend on a separately configured noninteractive helper.
- The consistency checker is limited and is not a complete filesystem repair tool.

## Development

See [development notes](docs/DEVELOPMENT.md) for the architecture, validation approach, and remaining work. Contributions should include a reproducible disk image or focused regression test when changing filesystem behavior. Never include personal drive contents in bug reports.

## License

MacNTFS is available under the [MIT license](LICENSE).
