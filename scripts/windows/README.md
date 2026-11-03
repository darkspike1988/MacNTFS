# Windows-written NTFS images

The engine is compared with images that the Microsoft driver (`ntfs.sys`) wrote. They are committed in `Tests/Fixtures/windows` (gzipped, 11 MB), so no Windows is needed to run the tests.

## How they are made

No Windows is installed. `build.py` turns a Windows 11 ARM installation ISO into a small bootable ISO that holds only the boot files, `boot.wim`, an `autounattend.xml` and a payload. Windows Setup starts WinPE and runs the payload (`run.cmd`) before it shows any screen:

1. `diskpart` partitions the empty second disk (GPT, one partition per scenario, fixed drive letters, `automount` off).
2. `format.com` formats each partition with NTFS (cluster sizes 4 KiB, 8 KiB, 64 KiB).
3. `files.cmd` fills the volumes with `copy`, `mklink`, `fsutil`, `compact` and `type`. The data comes from the payload; its SHA-256 hashes are computed by `build.py` before Windows sees it and end up in the manifests.
4. The volumes are dismounted, `fsutil dirty set` marks one volume dirty, the log is copied to a log partition and the VM shuts down.

`make-vm.sh` creates the VMware Fusion VM (no network, no TPM, no encryption, a flat NVMe disk), `extract.py` cuts the partitions out of the disk and writes images and manifests. There is no account, no licence and no network access involved.

```bash
python3 scripts/windows/build.py <Windows11_arm64.iso> <work-dir>      # payload, oracle.iso, expected.json
scripts/windows/make-vm.sh <vm-dir> <work-dir>/oracle.iso               # zeroes the disk each time
"/Applications/VMware Fusion.app/Contents/Public/vmrun" -T fusion start "<vm-dir>/NTFS Oracle WinPE.vmwarevm/NTFS Oracle WinPE.vmx" nogui
python3 scripts/windows/extract.py "<vm-dir>/NTFS Oracle WinPE.vmwarevm/NTFS Oracle WinPE-flat.vmdk" <work-dir>/expected.json <out-dir> 26100.4349
```

The VM shuts itself down after about 40 seconds. Zero the disk before each run (`make-vm.sh` does): leftover volumes of an earlier run are mounted by WinPE at boot and take the drive letters.

## What this covers and what not

- Covered: file sizes around cluster and record boundaries, nesting, Unicode names, a directory with 3000 files, named streams on files and on a directory, symbolic links (relative and absolute, file and directory), a junction, hard links, LZNT1 compression, zeroed and extended (sparse) files, attribute lists (300 hard links, 100 streams), a fragmented file, deleted files, and a dirty bit set by Windows.
- Not covered: 512-byte clusters (Windows refuses them: the virtual NVMe disk has 4 KiB physical sectors), hibernation files, EFS, deduplication, `$UsnJrnl` history and security descriptors of a long-running system, volumes larger than 160 MB.
- The ISO is Microsoft's and not part of this repository. The images contain only the test data and the file system structures that Windows wrote around it.
