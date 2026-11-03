# Advisory: releases v0.1.3 to v0.2.2 can write invalid NTFS data

Published 2026-11-03 at the top of the GitHub release notes of v0.1.3 through v0.2.2.

**Affected:** MacNTFS releases v0.1.3 through v0.2.2 (DMG downloads from GitHub Releases). v0.1.0 to v0.1.2 do not contain the write, format or repair code (checked in the release tags).

**What happened:** These releases let you write files to NTFS volumes, format disks as NTFS and "repair" volumes. A code review found that the write path can produce NTFS structures that Windows may reject, that the formatter does not create a complete NTFS volume, and that "repair" only clears the dirty flag. The app and the release notes described these functions as safe. They are not.

**What to do:**

1. Stop using the write, format and repair functions of these releases.
2. If you wrote to a volume: copy your files off, then run `chkdsk X:` in Windows. Run `chkdsk X: /f` only after you have a backup.
3. Do not format disks you care about with these releases.

**Fix:** The next release removes the write, format and repair code and corrects the README and website. It is read-only and its tests compare it with reference images.

Questions or damage reports: open an issue and include the Windows `chkdsk` output. Do not attach disk images with private data.
