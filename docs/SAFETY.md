# Safety

MacNTFS reads NTFS volumes. This page says what protects your data and what does not.

## Rules

1. **The code cannot write.** The write, format and repair code of earlier releases is removed. `BlockDevice` has no write method, `FileBlockDevice` opens read-only, and CI fails if the release binary imports a call that can change files (`scripts/readonly-check.sh` and a symbol check in `.github/workflows/ci.yml`).
2. **Refuse instead of guess.** Data that the engine cannot read correctly (encrypted data, Windows links) is refused with exit code 3. Wrong bytes without an error count as a test failure.
3. **No claims without evidence.** A feature is called working only when `docs/STATUS.md` names a test that shows it against an independent reference.

## What still can go wrong

- Reading a device that another driver has mounted for writing can return inconsistent data. The tool refuses such a device (exit code 4) unless you pass `--allow-mounted`. Reading an image is safer.
- A volume that Windows did not shut down cleanly (dirty flag, hibernation, Fast Startup) can show outdated data. The tool warns about both, but it does not replay the journal and reads the volume as it is.
- Reading from a device needs root. The tool opens it read-only, but run it only on devices you name explicitly.
- Hostile images: the parser checks sizes and offsets and is exercised with damaged images, but it has been fuzzed with a coverage-guided fuzzer only briefly (minutes per image, no finding). That is no proof. Treat images from untrusted sources with care.

## If you wrote to a volume with MacNTFS v0.1.3 to v0.2.2

Those releases had write, format and "repair" functions that could produce invalid NTFS data. A code review found, among other problems, that "repair" only cleared the dirty flag and that the formatter did not create a complete volume.

1. Stop writing to that volume with MacNTFS.
2. Copy off the files you need. Compare important files with their originals.
3. Check the volume in Windows without repairing first: `chkdsk X:`. If it reports errors, run `chkdsk X: /f` only after you have a backup.
4. Open an issue if you see damage. Include the Windows `chkdsk` output, not the disk image.

## Reporting a security problem

Open an issue marked `security` without exploit details, or contact the maintainer through the GitHub profile.
