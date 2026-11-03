# Making MacNTFS Apple-native

## How Tuxera NTFS for Mac is built (installed on the author's Mac, version 27.0.1)

Only the package layout was looked at: bundle files, property lists, code signature, linked libraries, and the option strings of the mount helper. No code of the driver was decompiled or is used here.

| Part | What it is |
| --- | --- |
| `/Library/Filesystems/tuxera_ntfs.fs` | A classic file system bundle (`fs` package type). Its `Info.plist` lists the media types it probes (`FSMediaTypes`, probe order 1940) and runs `tuxera_ntfs.util -p` to probe. |
| `mount_tuxera_ntfs`, `newfs_tuxera_ntfs`, `tuxera_ntfs.util` | Command line helpers for mount, format and probe, as universal binaries (arm64, x86_64 and old PowerPC and i386 slices), signed with the hardened runtime. They link only the C runtime. |
| `Support/10.4`, `10.5`, `10.9` | One **kernel extension** per kernel generation (`tuxera_ntfs.kext`). The one examined declares dependencies on the `bsd`, `iokit`, `libkern`, `mach` and `unsupported` kernel interfaces (KPIs). |
| Menu bar agent, preference pane, autorepair tool | A launch agent (`com.tuxera.ntfs.agent`) with a menu bar app, a preference pane and `tuxera_ntfs_autorepair`. |
| Mount options in the helper | `rdonly`, `recover`, `remove_hiberfile,force` and `probe`. So it can delete a hibernation file to mount a volume that is not cleanly shut down. MacNTFS never does that. |

Observations on this Mac: the kernel extension is staged but not loaded (`kmutil showloaded` lists nothing of Tuxera), and the package contains no FSKit extension (`.appex`). On current macOS a third-party kernel extension needs reduced security and a restart, and Apple has been moving file systems to user space. That is the route to follow.

## The Apple-native design

| | Kernel extension (Tuxera) | FSKit module (Apple's way) |
| --- | --- | --- |
| Runs in | the kernel | user space, sandboxed |
| A bug can | crash the machine, corrupt other volumes | crash the extension |
| Install | package with root, approval, reboot | an app that contains the extension; the user turns it on under *System Settings, General, Login Items & Extensions, File System Extensions* |
| Needs | kernel signing and notarization, user opt-in to kernel extensions | the restricted entitlement `com.apple.developer.fskit.fsmodule` (paid Apple Developer account), app sandbox, provisioning profile |
| Used by Apple for | legacy | exFAT, FAT (msdos), FTP (see [FSKIT-NOTES.md](FSKIT-NOTES.md)) |

Parts of the MacNTFS app:

1. **`NTFSCore`** (done): the engine, read-only by type.
2. **`ReadOnlyFileSystem`** (done, 9 tests): the operations a file system module asks for, by item ID: `item`, `lookup`, `contents` (paged), `read`, `readLink`, `streamNames`. The write operations exist and always return `FileSystemError.readOnly` (POSIX `EROFS`). It has a bounded record cache, hides the NTFS metadata files and maps every error to a POSIX code.
3. **FSKit extension** (not written): a subclass of `FSUnaryFileSystem` that probes with the boot sector check of `NTFSCore` and returns an `FSVolume` subclass that calls `ReadOnlyFileSystem`. Media types: the Microsoft Basic Data partition GUID `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` and the content hint `Windows_NTFS`. No privileged helper, no root: FSKit gives the extension the block device resource.
4. **Host app** (not written): a small SwiftUI app that shows the state of a volume (the `probe` information: dirty flag, hibernation, mount state), explains how to turn the extension on, and never offers a write, a repair or a "remove hibernation file" button.

Rules for the module that come from the comparison:

- Always read-only. A dirty volume is mounted read-only with a visible warning. A volume with a hibernation file is mounted read-only with a warning or refused; the user decides in the app, nothing is deleted.
- No automatic repair.
- Unsupported features (encryption, reparse points that are not links) are refused per file, not hidden.

## What is missing, and what blocks it

- The FSKit adapter has to be written against the SDK it is built with. The SDK in use here (macOS 27) marks the `FSVolume.Operations` protocols as deprecated in favour of handler based ones, so the adapter should be written and tested on that SDK, not from memory.
- Running the extension needs the entitlement, hence a paid Apple Developer account. Without it the extension can be compiled but macOS will not load it. That is a decision for the author (see [STATUS.md](STATUS.md)).
- Until then, the engine and the command line tool are the supported way to read an NTFS volume.
