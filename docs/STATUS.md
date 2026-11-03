# Status

Last updated: 2026-11-03. Maturity levels: **none** (not present), **skeleton** (compiles, does not work), **prototype** (works on simple cases, known defects), **locked** (code exists but is disabled because it can destroy data).

Evidence means a test in this repository. All tests use images produced by this project itself. No feature has been validated against Windows `chkdsk` or another independent reader yet.

| Feature | Maturity | Evidence | Notes |
|---|---|---|---|
| Boot sector and BPB parsing | prototype | unit tests | Arithmetic is not bounds-checked. Manipulated values can crash the parser. |
| MFT record parsing, fixups | prototype | unit tests | Fixup step uses the device sector size. 4096-byte sectors untested. |
| Runlist decoding | prototype | unit tests | |
| Directory listing and path lookup | prototype | unit tests | Linear scan, ASCII-style case folding, not `$UpCase`. |
| File read (`cat`) | prototype | unit tests | Missing `$DATA`, compression, encryption and attribute lists give empty or raw data instead of an error. |
| Alternate data streams, hard links, reparse points, symlinks | none | none | |
| Forensics (deleted record scan, hex dump, surface scan) | prototype | unit tests | Not validated. "Recovered" does not mean intact. |
| Volume check (`check`, no repair) | prototype | unit tests | Checks boot sector, backup boot sector, MFT record 0 and dirty flag only. A clean result does not mean the volume is healthy. |
| Read-only app (browse, forensics) | prototype | none | Needs root or an image to read devices. |
| Write file | locked | unit tests (self-check only) | Known defects, see SAFETY.md. |
| Format | locked | unit tests (self-check only) | Does not produce a volume Windows is known to accept. |
| Repair | locked | unit tests (self-check only) | Only clears the dirty flag. |
| FSKit adapter | skeleton | none | Probe and load only. No extension target, nothing is mounted. |
| Privileged helper for the app | locked | none | |
| Windows validation (`chkdsk`) | none | none | |
| Fuzzing | none | none | |

How to move a row up: link a test that shows the behavior against an independent reference (a manifest written on Windows, or `ntfscat`/`fls` output) and update this table in the same change.
