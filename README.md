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
* **Full Read & Write Capability:** Seamlessly write, import, and export files to NTFS volumes with automatic filename sanitization.
* **Forensic File Recovery (Undelete & Carving):** Scan inactive MFT records to discover deleted files and carve data back to Mac with zero data loss.
* **Hex Inspector & Sector Diagnostics:** Low-level hexadecimal cluster & sector viewer and non-destructive hardware surface scan for bad blocks.
* **Format to NTFS:** Initialize partitions and disks as standard Windows NTFS with configurable cluster sizes.
* **First Aid & Repair:** Detect and repair filesystem inconsistencies, clear dirty flags from Windows unclean unmounts, and restore boot sectors.
* **Virtual Disk Image Studio:** Create, format, and mount `.img` / `.raw` NTFS virtual disk images on demand.
* **Menu Bar Quick Access:** Live status monitor in the macOS menu bar showing connected NTFS volumes and unmount state.
* **Built-in File Explorer:** Drag-and-drop file transfers directly between Mac Finder and NTFS volumes without third-party drivers.
* **Zero Kernel Extensions:** Runs fully in user space via Apple's modern `fskitd` ecosystem (no SIP disabling, no Recovery Mode reboots).
* **Strict Memory Safety:** Implemented in pure Swift with strict concurrency checks and bounds-safe binary streaming.
* **Clean-Room Engineering:** Built from open specifications ([MS-FSCC], standard forensic documentation) without proprietary third-party code.

---

## 🖥 The MacNTFS App

The macOS application provides an Apple-like experience:
1. **Drive Dashboard:** Shows storage capacity gauges, cluster size, MFT offset, and volume serial numbers.
2. **Forensics & Data Recovery Suite:** 
   * **File Carving & Undelete:** Deep scan over Master File Table to restore deleted files.
   * **Hex Inspector:** Inspect raw boot sectors, MFT records, and cluster bytes with ASCII view.
   * **Surface Scan:** Hardware-level sector verification to detect failing disk blocks.
3. **First Aid & Maintenance:** Instant diagnostic scan for Boot Sector, Backup Boot Sector, MFT integrity, and Dirty Flag status, with one-click automated repair.
4. **Format Wizard:** Erase and format partitions to Windows NTFS 3.1 directly within an Apple Disk Utility-inspired workflow.
5. **Interactive Explorer:** Direct access to directories, file metadata, drag-and-drop file imports from Mac, and file exports.
6. **Disk Image Support:** Create new blank NTFS images (.img) or inspect existing ones via drag-and-drop.

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

The included CLI tool `macntfs` allows inspecting, formatting, repairing, and writing to NTFS drives directly:

```bash
# Clone the repository
git clone https://github.com/darkspike1988/MacNTFS.git
cd MacNTFS

# Build the project
swift build -c release

# Inspect an NTFS disk image or partition
.build/release/macntfs probe /path/to/disk.img

# Format a partition or file as Windows NTFS
.build/release/macntfs format /dev/rdisk4s1 "MyNTFSDrive" 4096

# Create a fresh 100 MB NTFS virtual disk image
.build/release/macntfs create-image /tmp/sample.img 100 "NTFS_Drive"

# Check integrity and auto-repair dirty unmount flags
.build/release/macntfs check /path/to/disk.img --repair

# Write/import a file into the NTFS volume
.build/release/macntfs write /path/to/disk.img ~/Downloads/photo.jpg "photo.jpg"

# List directory contents
.build/release/macntfs ls /path/to/disk.img /

# Read a file to stdout
.build/release/macntfs cat /path/to/disk.img /photo.jpg
```

---

## 🗺 Roadmap

| Phase | Milestone | Status |
| :--- | :--- | :---: |
| **Phase 1** | **Read-Only Core Engine** (VBR/BPB, Fixups, MFT Parsing, Runlists, B-Tree Listing, CLI) | ✅ **Done** |
| **Phase 2** | **Native FSKit Integration** (`MacNTFSFileSystem`, `FSUnaryFileSystemOperations`, `FSBlockDeviceResource` bridge) | ✅ **Done** |
| **Phase 3** | **Write Engine Architecture** (`BitmapManager` Cluster Allokator, `DataRunEncoder`, `MFTRecordBuilder` mit Fixup-Array) | ✅ **Done** |
| **Phase 4** | **NTFS Formatter & Maintenance** (Native `mkfs.ntfs`, First Aid Check & Auto-Repair, Dirty Flag clearing) | ✅ **Done** |
| **Phase 5** | **GUI App & Distribution** (SwiftUI App mit Menu Bar, Drag-and-Drop File Import, DMG Packaging, GitHub Actions CI) | ✅ **Done** |

---

## 🧪 Testing

MacNTFS includes a test suite covering runlists, binary decoding, fixup integrity, and boot sector parsing:

```bash
swift test
```

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.  
Open-source software developed for the macOS community.
