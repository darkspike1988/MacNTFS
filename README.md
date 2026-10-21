# MacNTFS

> **High-Performance, Pure Swift NTFS File System Engine for macOS**  
> *Architected for Apple FSKit (User-Space) • Clean-Room Implementation • Memory-Safe*

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B%20(Sonoma%20%7C%20Sequoia)-blue.svg)](https://apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 🎯 Overview

**MacNTFS** is an open-source, modern NTFS file system implementation written in Swift. It is designed to replace legacy, kernel-dependent drivers (such as outdated KEXTs or macFUSE workarounds) with a native, user-space architecture built on Apple's **FSKit**.

* **Zero Kernel Extensions:** Runs fully in user space via Apple's modern `fskitd` ecosystem (no SIP disabling, no Recovery Mode reboots).
* **Strict Memory Safety:** Implemented in pure Swift with strict concurrency checks and bounds-safe binary streaming.
* **Clean-Room Engineering:** Built from open specifications ([MS-FSCC], standard forensic documentation) without proprietary third-party code.

---

## 🏗 Architecture

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
| **Phase 2** | **Native FSKit Integration** (Mounting NTFS volumes read-only in Finder via `FSKit.framework`) | 🔄 In Progress |
| **Phase 3** | **Safe Write Engine** (Cluster Allocation via `$Bitmap`, MFT Record Creation, B-Tree Mutation) | ⏳ Planned |
| **Phase 4** | **macOS Interoperability** (Extended Attributes `xattr` via Named Streams, Symlinks, Timestamps) | ⏳ Planned |
| **Phase 5** | **GUI App & Distribution** (Menu Bar App, Auto-Mounting, Sparkle Auto-Update, DMG Release) | ⏳ Planned |

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
