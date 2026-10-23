# Developing MacNTFS

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/NTFSCore` | NTFS parsing, allocation, directory indexes, file creation, consistency checks, and inspection. |
| `Sources/NTFSCore/Format` | Native NTFS 3.1 formatter; image and designated USB validation. |
| `Sources/NTFSCore/AttributeResolver.swift`, `NTFSCompression.swift` | `$ATTRIBUTE_LIST` and multi-extent streams; LZNT1 decompression. |
| `Sources/NTFSCore/NTFSStreamWriter.swift`, `NTFSWriteSafety.swift` | In-place stream changes and deferred directory entries; journal, hibernation and dirty-state checks. |
| `Sources/NTFSCore/FSKitAdapter.swift` | FSKit resource bridge, volume operations, open/close handling, and maintenance operations. |
| `Sources/MacNTFSCli` | `macntfs` command line interface. |
| `Sources/MacNTFSApp` | SwiftUI app, drive discovery, browsing, and helper bridge. |
| `Tests/NTFSCoreTests` | Core, writer regression, formatter, and read/stream tests. `Fixtures/tuxera-features.img.lzfse` is an image written by an independent driver. |
| `scripts/build_dmg.sh` | App/helper bundling and DMG creation. |

## Local validation

```sh
swift test
swift build -c release
```

Run focused tests while developing, followed by the complete suite before a release. A passing core test does not prove that a Finder mount, physical device format, or privileged app operation works.

For write changes, validate file contents after reopening the image. Include duplicate names, Unicode names, fragmented allocation, directory growth, MFT growth, insufficient space, and I/O failure paths where relevant. Check metadata and allocation consistency with an independent reader. An image produced and read by the same implementation can reproduce the same defect in both paths.

For physical tests, record the drive model, serial when available, capacity, partition layout, macOS version, build commit, exact commands, and results. Identify the removable device again before every destructive operation; disk identifiers can change after reconnection. Use only a dedicated disposable test device.

## FSKit development signing

`./scripts/build_dmg.sh 0.3.0-dev` bundles the app, helper, resources, and filesystem extension. The default ad-hoc signature permits build and registration checks, but does not authorize the restricted FSKit entitlement for mounting. Set `MACNTFS_SIGNING_IDENTITY` to an Apple-issued identity and `MACNTFS_FSKIT_PROFILE` to the extension's provisioning profile. The profile must authorize `org.macntfs.MacNTFS.filesystem` and `com.apple.developer.fskit.fsmodule`; packaging embeds it and signs the extension with its application and team identifiers before signing the outer app.

Xcode must have an Apple Developer account configured to create a development provisioning profile. A signing certificate alone is insufficient. Successful `codesign --verify --deep --strict` and an enabled entry in `pluginkit` do not establish that FSKit can discover or launch the module. Verify it in `FSClient.shared.installedExtensions`, then test a disposable image with `mount -F -t macntfs` at an explicit mount point.

The [23 October USB report](validation/usb-native-20261023.json) records three native format and 67-file hash verification cycles with 1, 4, and 64 KiB clusters. The independent kernel mount used an installed external filesystem implementation. Physical USB reconnection and MacNTFS's own Finder mount are still pending.

## Remaining implementation work

- Validate the complete provisioned FSKit runtime path, including Finder mounting, file operations, eject, and physical reconnect.
- Validate native formatted volumes on Windows.

These are development tasks, not supported release features. Promote a feature in the README only when its complete user path has been tested.

## Contribution scope

Keep changes focused and document the supported geometry and metadata assumptions. Preserve existing files when imports collide. Refuse unsafe or unsupported writes with an actionable error. Keep third-party notices required by any included dependency or source material; do not add proprietary code, binary extracts, or private device data to the repository.

Follow the [release checklist](RELEASE_CHECKLIST.md) when preparing a public artifact.
