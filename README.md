# MacNTFS

> **High-Performance, Pure Swift NTFS File System Engine for macOS**  
> *Architected for Apple FSKit (User-Space) • Clean-Room Implementation • Memory-Safe*

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Sonoma%20%7C%20Sequoia)-blue.svg)](https://apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 🎯 Overview

**MacNTFS** is an open-source, modern NTFS file system implementation and management utility written in Swift. It is designed to replace legacy, kernel-dependent drivers (such as outdated KEXTs or macFUSE workarounds) with a native, user-space architecture built on Apple's **FSKit**.

* **Apple-Native GUI:** Modern macOS interface built with SwiftUI, SF Pro typography, NavigationSplitView, and translucent Apple materials.
* **Menu Bar Quick Access:** Live status monitor in the macOS menu bar showing connected NTFS volumes and unmount state.
* **Built-in File Explorer:** Browse and export files directly from NTFS partitions and raw disk images without third-party drivers.
* **Zero Kernel Extensions:** Runs fully in user space via Apple's modern `fskitd` ecosystem (no SIP disabling, no Recovery Mode reboots).
* **Strict Memory Safety:** Implemented in pure Swift with strict concurrency checks and bounds-safe binary streaming.
* **Clean-Room Engineering:** Built from open specifications ([MS-FSCC], standard forensic documentation) without proprietary third-party code.

---

## 🖥 The MacNTFS App

The macOS application provides an Apple-like experience:
1. **Drive Dashboard:** Shows storage capacity gauges, cluster size, MFT offset, and volume serial numbers.
2. **Integrity Guard:** Warns when a volume was uncleanly disconnected in Windows (Dirty Flag), protecting against corruption.
3. **Interactive Explorer:** Direct access to directories, file metadata, and export-to-Mac functionality.
4. **Disk Image Support:** Mount and inspect `.img`, `.raw`, and `.vhd` disk images via drag-and-drop.

---

## 🚀 Installation & Downloads

Download the latest release DMG from the [Releases Page](https://github.com/darkspike1988/MacNTFS/releases):

1. Open `MacNTFS-x.x.x-arm64.dmg`.
2. Drag `MacNTFS.app` into your **Applications** folder.
3. Launch MacNTFS from Launchpad or Spotlight.

---

## 🛠 Command-Line Interface (`macntfs`)

```
┌────────────────────────────────────────────────────────┐
│                   macOS VFS (Kernel)                   │
└───────────────────────────┬────────────────────────────┘
                            │ Mach IPC / XPC
┌───────────────────────────▼────────────────────────────┐
│                    fskitd (Daemon)                     │
└───────────────────────────┬────────────────────────────┘
                            │ FSKit API
┌───────────────────────────▼────────────────────────────┐
│  MacNTFS.app (App & FSKit Extension)                   │
│  ├─ FSKit Adapter (FSFileSystem, FSVolume, FSItem)     │
│  ├─ NTFSCore Engine                                    │
│  │   ├─ BootSector & BPB Parser                        │
│  │   ├─ Multi-Sector Fixup Verification (USA)          │
│  │   ├─ MFT Record & Attribute Engine                  │
│  │   ├─ Runlist (Data Runs) Decompressor               │
│  │   └─ B-Tree Directory Indexing ($I30)               │
│  └─ Block Device I/O (Async POSIX pread / Cache)       │
└────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start (CLI)

The included CLI tool `macntfs` allows inspecting NTFS drives and disk images directly:

```bash
# Clone the repository
git clone https://github.com/darkspike1988/MacNTFS.git
cd MacNTFS

# Build the project
swift build -c release

# Inspect an NTFS disk image or partition
.build/release/macntfs probe /path/to/disk.img

# List directory contents
.build/release/macntfs ls /path/to/disk.img /

# Read a file to stdout
.build/release/macntfs cat /path/to/disk.img /Documents/Notes.txt

# Inspect a raw MFT Record (e.g., Record 0 for $MFT or Record 5 for Root)
.build/release/macntfs info /path/to/disk.img 5
```

---

## 🗺 Roadmap

| Phase | Milestone | Status |
| :--- | :--- | :---: |
| **Phase 1** | **Read-Only Core Engine** (VBR/BPB, Fixups, MFT Parsing, Runlists, B-Tree Listing, CLI) | ✅ **Done** |
| **Phase 2** | **Native FSKit Integration** (`MacNTFSFileSystem`, `FSUnaryFileSystemOperations`, `FSBlockDeviceResource` bridge) | ✅ **Done** |
| **Phase 3** | **Write Engine Architecture** (`BitmapManager` Cluster Allokator, `DataRunEncoder`, `MFTRecordBuilder` mit Fixup-Array) | ✅ **Done** |
| **Phase 4** | **macOS Interoperability** (Extended Attributes `xattr` via Named Streams, Symlinks, Timestamps) | 🔄 In Progress |
| **Phase 5** | **GUI App & Distribution** (SwiftUI App mit Menu Bar, Apple Storage Bar, Sparkle Auto-Update, DMG Release) | ✅ **Done** |

---

## 🧪 Testing

MacNTFS includes a test suite covering runlists, binary decoding, fixup integrity, and boot sector parsing:

```bash
swift test
```

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.  
Copyright (c) 2026 **Michael Katschko**.
