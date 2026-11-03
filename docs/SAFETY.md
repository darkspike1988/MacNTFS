# Safety

MacNTFS is experimental. This page says what is locked, why, and what to do if you already used an earlier release.

## Rules

1. **Read-only by default.** The command line tool and the app only read. The app opens devices read-only.
2. **Writing, formatting and repairing are locked.** The functions refuse to run unless the environment variable `MACNTFS_EXPERIMENTAL_UNSAFE=1` is set. Use that only on throw-away disk images, never on a disk with data you want to keep.
3. **No claims without evidence.** A feature is called working only when `docs/STATUS.md` links to a test that shows it against an independent reference.

## Why it is locked

A code review of the earlier write, format and repair code found problems. Not all findings are verified by running them. Reported by reviewers:

- The writer does not update the MFT bitmap, inserts directory index entries without sorting, truncates records silently and has no `$LogFile` handling. (Reported by one reviewer, not confirmed by a second.)
- `check --repair` only clears the dirty flag. It does not check or replay the `$LogFile` journal, so it can hide real damage.
- The formatter writes empty placeholders for several system files and uses fixed layout values. Disks larger than about 1 GiB can overlap the cluster bitmap. (Reported, partly verified.)
- The code that restores multi-sector fixups uses the device sector size. NTFS uses 512-byte steps (general NTFS knowledge). On 4096-byte-sector disks this can produce wrong data without an error. (Code verified, behavior not tested.)
- The read path can return empty or raw bytes instead of an error for missing `$DATA`, compressed and encrypted files.
- The command line tool also had commands that write.

## If you wrote to a volume with MacNTFS up to v0.2.2

1. Stop writing to that volume with MacNTFS.
2. Copy off the files you need. Compare important files with their originals.
3. Check the volume in Windows without repairing first: `chkdsk X:`. If it reports errors, run `chkdsk X: /f` only after you have a backup.
4. Open an issue if you see damage. Include the Windows `chkdsk` output, not the disk image.

## What this project does not do

- It does not replay the NTFS journal.
- It does not detect Windows hibernation or Fast Startup state reliably. Reading a volume that Windows has not shut down cleanly can show outdated data.
- It does not coordinate with other drivers. Do not read a device through MacNTFS while another driver has it mounted writable.

## Reporting a security problem

Open an issue marked `security` without exploit details, or contact the maintainer through the GitHub profile.
