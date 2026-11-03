#!/usr/bin/env python3
"""Cuts the NTFS volumes that WinPE wrote out of the virtual disk and writes images with manifests.

Usage: extract.py <disk-flat.vmdk> <expected.json> <out-dir> <windows-build>
For every scenario of build.py it writes <out-dir>/win-<name>.img and win-<name>.manifest.json in the
format of the other corpus manifests. The expected hashes come from build.py (computed from the payload
before Windows wrote anything). The partition holding the log is written as win-log.img, without manifest.
"""
import json, os, struct, sys


def gpt_partitions(disk):
    disk.seek(512)
    header = disk.read(92)
    if header[:8] != b"EFI PART":
        sys.exit("no GPT header on the disk (did the VM finish?)")
    entries_lba, count, size = struct.unpack_from("<QII", header, 72)
    disk.seek(entries_lba * 512)
    out = []
    for i in range(count):
        entry = disk.read(size)
        if entry[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", entry, 32)
        out.append((first * 512, (last - first + 1) * 512))
    return out


def main(vmdk, expected_path, out_dir, build):
    expected = json.load(open(expected_path))
    names = expected["partitions"]
    os.makedirs(out_dir, exist_ok=True)
    with open(vmdk, "rb") as disk:
        parts = gpt_partitions(disk)
        if len(parts) != len(names):
            sys.exit(f"disk has {len(parts)} partitions, expected {len(names)}")
        for part, (start, length) in zip(names, parts):
            disk.seek(start)
            boot = disk.read(512)
            if boot[3:11] != b"NTFS    ":
                sys.exit(f"partition {part['name']} does not start with an NTFS boot sector")
            sector = struct.unpack_from("<H", boot, 11)[0]
            cluster = sector * boot[13]
            image = f"win-{part['name']}.img"
            disk.seek(start)
            with open(os.path.join(out_dir, image), "wb") as out:
                remaining = length
                while remaining:
                    chunk = disk.read(min(remaining, 8 << 20))
                    out.write(chunk)
                    remaining -= len(chunk)
            if part["name"] == "log":
                continue
            manifest = {"schema": 1, "image": image, "tool": f"Windows ntfs.sys ({build}, WinPE)",
                        "sectorSize": sector, "clusterSize": cluster, "volumeLabel": part["label"],
                        "dirty": part["dirty"], "entries": expected[part["name"]]}
            with open(os.path.join(out_dir, f"win-{part['name']}.manifest.json"), "w") as f:
                json.dump(manifest, f, indent=1)
            print(f"{image}: {len(expected[part['name']])} entries, cluster {cluster}")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
