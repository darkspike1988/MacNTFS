# The app and the FSKit extension

`NTFSFSKit` (in `Sources/NTFSFSKit`) is the file system module as a Swift package product: it compiles and its attribute mapping is tested (`Tests/NTFSFSKitTests`). It has never been loaded by macOS, because that needs an app extension that is signed with the restricted entitlement `com.apple.developer.fskit.fsmodule`, and that needs a paid Apple Developer account. These files are the templates for that Xcode part.

`Package.swift` builds `NTFSFSKit` only if the active Xcode has the macOS 27 FSKit headers (`FSVolumeHandlerResult.h`), so older toolchains and Linux still build everything else. `NTFS_FSKIT=1` forces it on, `NTFS_FSKIT=0` leaves it out.

## Create the Xcode project (needs Xcode 27 and the developer account)

1. New project, macOS App (SwiftUI), name `MacNTFS`. Add this repository as a local Swift package and link `NTFSCore` into the app.
2. Add a target of the type *File System Extension* (FSKit) named `NTFSExtension`. Link the package product `NTFSFSKit`.
3. Replace the generated `Info.plist`, entitlements and source file of the target with the ones in `App/NTFSExtension`. Set the deployment target to macOS 27 for the extension.
4. Signing: select the team, let Xcode create the provisioning profile with the FSKit module capability, enable the app sandbox.
5. Build and run the app once. Turn the extension on in *System Settings, General, Login Items & Extensions, File System Extensions*.
6. Try it with an image that is not your only copy of the data:

   ```bash
   hdiutil attach -nomount -readonly -imagekey diskimage-class=CRawDiskImage Tests/Fixtures/mini.img   # prints /dev/diskN
   mount -F -t ntfs -o rdonly /dev/diskN /tmp/mini   # the mount point has to exist
   ```

## What to check first

- Whether the keys of `Info.plist` are accepted (probe order, media types, no `FSProbeExecutable`). They follow Apple's own modules but are not verified for a module written in Swift.
- That `ls`, `cat` and a Finder window show the same hashes as `macntfs cat` for the images in `Tests/Fixtures`, and that every write fails with a read-only error.
- That a dirty volume (`win-dirty`) is offered as "usable but limited".

## The host app

A small SwiftUI app is still to be written: it shows the result of `probe` (dirty flag, hibernation, mount state) for the attached NTFS volumes and explains how to turn the extension on. It must not offer a write, a repair, or a button that removes a hibernation file.
