# Notes for an FSKit module on top of NTFSCore

These notes record what the structure of Apple's own FSKit modules (macOS 27, `/System/Library/ExtensionKit/Extensions/com.apple.fskit.exfat.appex`) shows about how a file system module is built. They are based on public metadata only: `Info.plist`, the code signature entitlements, the linked frameworks, the imported classes and the Objective-C selector names. No code was decompiled and none of it is copied. The module is written from scratch against the public `FSKit` API.

## Packaging

- An ExtensionKit extension (`.appex`, package type `XPC!`) with the extension point `com.apple.fskit.fsmodule`.
- `EXExtensionPrincipalClass` names the class that subclasses `FSUnaryFileSystem`.
- `FSMediaTypes` in the `Info.plist` tells the system which partition content it handles (a GUID or a hint such as `Windows_NTFS`), with a probe order. Apple's exFAT module also claims `Windows_NTFS` with a probe order of 2000 and probes by running a helper tool, so a NTFS module has to decide which probe order it wants and must not claim exFAT volumes.
- `FSCheckOptionSyntax` and `FSFormatOptionSyntax` list the option letters for check and format. A read-only module can leave both out.
- Entitlements of Apple's module: `com.apple.developer.fskit.fsmodule` and `com.apple.security.app-sandbox`. The FSKit entitlement is restricted. A module from a third party needs it in its provisioning profile, which needs a paid Apple Developer account. Without it the module does not load on a normal system. This is the reason why MacNTFS ships a library and a command line tool first.

## Shape of the code

- The module links `FSKit`, `Foundation`, `CoreFoundation`, `IOKit` and a few system libraries. The file system core is plain C; a thin Objective-C layer adapts it.
- Classes used: `FSUnaryFileSystem` (one resource, one volume), `FSBlockDeviceResource`, `FSProbeResult`, `FSVolume`, `FSFileName`, `FSContainerStatus`, `FSTaskProgressUpdater`; errors via `FSKitErrorDomain` and a helper that turns POSIX errors into `NSError`.
- Lifecycle methods of the file system object: `probeResource:replyHandler:`, `loadResource:options:replyHandler:`, `unloadResource:options:replyHandler:`, `didFinishLoading`; for tools `startCheckWithTask:options:error:`, `startFormatWithTask:options:error:`, `wipeResource:completionHandler:`.

## What this means for MacNTFS

- `NTFSCore` already has what the lifecycle needs: `BlockDevice` for the resource, the boot sector check for probing, `NTFSVolume` for loading, the dirty flag and the hibernation state for the decision whether to mount at all.
- A first module maps the read operations of `FSVolume.Operations` to `NTFSVolume`: look up an item, enumerate a directory, read attributes, read file data and read a symbolic link. Every operation that would change something returns `EROFS`. Check and format are not offered.
- Probe returns usable only for a valid NTFS boot sector. A volume with the dirty flag or a hibernation file is mounted read-only with a warning, or not at all; that is a decision for the module, to be made before it is written.
- FSKit changed in the macOS 27 SDK (the `FSVolume.Operations` protocols are marked deprecated in favour of handler based ones). The module has to be written against the SDK it is built with, so it cannot be completed here without that SDK and a signing identity.
