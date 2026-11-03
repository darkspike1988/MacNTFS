#!/usr/bin/env python3
"""Builds a bootable WinPE ISO that writes NTFS test volumes with the Microsoft driver (ntfs.sys).

How it works: the ISO is the Windows 11 ARM installation medium reduced to its boot files and boot.wim,
plus an autounattend.xml and a payload. Windows Setup runs the payload's run.cmd in WinPE before it shows
any screen. run.cmd partitions the second (empty) virtual disk, formats one NTFS volume per scenario,
fills it with files from the payload, and shuts the machine down. No Windows is installed, no account,
no licence and no network are involved. extract.py then cuts the volumes out of the virtual disk and
writes images plus manifests into Tests/Corpus/out, with expected hashes computed here, from the payload,
before Windows touches anything.

Usage: build.py <windows-iso> <work-dir>
Writes <work-dir>/oracle.iso, <work-dir>/expected.json and the layout of the disk.
"""
import hashlib, json, os, random, shutil, subprocess, sys

MKISOFS = "/Applications/VMware Fusion.app/Contents/Library/mkisofs"
MB = 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Payload:
    """Stores every distinct content once and hands out its path on the ISO."""

    def __init__(self, root):
        self.dir = os.path.join(root, "payload", "d")
        os.makedirs(self.dir, exist_ok=True)

    def put(self, data):
        name = sha(data)[:20] + ".bin"
        with open(os.path.join(self.dir, name), "wb") as f:
            f.write(data)
        return "%S%\\d\\" + name


class Vol:
    def __init__(self, name, label, letter, payload, unit=None, size_mb=160):
        self.name, self.label, self.letter, self.unit, self.size_mb = name, label, letter, unit, size_mb
        self.payload, self.entries, self.cmds, self.dirty = payload, {}, [], False

    # --- helpers that record an expected entry and the command that makes it
    def path(self, p):
        return f"{self.letter}:" + p.replace("/", "\\")

    def mkdir(self, p, streams=None):
        self.cmds.append(f'mkdir "{self.path(p)}"')
        self.add(p, "dir", streams=streams)
        for n, d in (streams or {}).items():
            self.cmds.append(f'type "{self.payload.put(d)}" > "{self.path(p)}:{n}"')

    def file(self, p, data, streams=None, typ="file"):
        self.cmds.append(f'copy /b "{self.payload.put(data)}" "{self.path(p)}" >nul')
        self.add(p, typ, data, streams=streams)
        for n, d in (streams or {}).items():
            self.cmds.append(f'type "{self.payload.put(d)}" > "{self.path(p)}:{n}"')

    def add(self, p, typ, data=None, expect="ok", link=None, streams=None, note=None, reparse=None):
        e = {"path": p, "type": typ, "size": None if data is None else len(data),
             "sha256": None if data is None else sha(data), "expect": expect, "linkTarget": link,
             "streams": [{"name": n, "size": len(d), "sha256": sha(d)} for n, d in (streams or {}).items()]}
        if note:
            e["note"] = note
        if reparse:
            e["reparse"] = reparse
        self.entries[p] = e

    def run(self, command):
        self.cmds.append(command)


def blob(rng, size, kind="random"):
    if kind == "text":  # compresses well
        words = [b"alpha", b"beta", b"gamma", b"delta", b"NTFS", b"cluster", b"record", b"index"]
        out = bytearray()
        while len(out) < size:
            out += rng.choice(words) + b" "
        return bytes(out[:size])
    return bytes(rng.getrandbits(8) for _ in range(size))


def build_volumes(payload):
    rng = random.Random(20261103)
    letters = iter("GHIJKLMNOQRSTUVW")  # not P: the installation medium holds it in WinPE
    log = Vol("log", "LOG", next(letters), payload, size_mb=64)
    vols = []

    # basic: sizes around cluster and record boundaries, nesting, odd names
    v = Vol("basic", "WIN-BASIC", next(letters), payload)
    for size in (0, 1, 511, 512, 513, 700, 1023, 1024, 1025, 4095, 4096, 4097, 20000, 65536, 262144, 1100000):
        v.file(f"/f{size}.bin", blob(rng, size))
    v.mkdir("/dir with spaces")
    v.file("/dir with spaces/nested file.txt", blob(rng, 700, "text"))
    v.mkdir("/a"); v.mkdir("/a/b"); v.mkdir("/a/b/c")
    v.file("/a/b/c/deep.bin", blob(rng, 9000))
    v.mkdir("/uni")
    for name, size in (("Grüße-äöü.txt", 300), ("日本語.txt", 1500), ("ǅ-Ǆ-ǆ.txt", 40)):
        v.file(f"/uni/{name}", blob(rng, size))
    vols.append(v)

    for name, unit in (("c8k", "8192"), ("c64k", "64K")):
        v = Vol(name, f"WIN-{name.upper()}", next(letters), payload, unit=unit)
        for size in (0, 100, 513, 5000, 70000, 300000):
            v.file(f"/f{size}.bin", blob(rng, size))
        v.mkdir("/d")
        v.file("/d/x.txt", blob(rng, 800, "text"))
        vols.append(v)

    # many: a directory with a B-tree index written by Windows
    v = Vol("many", "WIN-MANY", next(letters), payload)
    v.mkdir("/many")
    v.run(f'for /L %%i in (1,1,3000) do >"{v.letter}:\\many\\f%%i.txt" echo %%i')
    for i in range(1, 3001):
        v.add(f"/many/f{i}.txt", "file", f"{i}\r\n".encode())
    vols.append(v)

    # ads
    v = Vol("ads", "WIN-ADS", next(letters), payload)
    v.mkdir("/ads", streams={"dirstream": blob(rng, 2500, "text")})
    v.file("/ads/big.bin", blob(rng, 204800), streams={"meta": blob(rng, 60000, "text"), "small": b"hello"})
    v.file("/ads/small.txt", b"tiny\r\n", streams={"s1": b"one", "s2": b"two" * 100})
    vols.append(v)

    # links
    v = Vol("links", "WIN-LINKS", next(letters), payload)
    v.mkdir("/links"); v.mkdir("/links/dir")
    v.file("/links/target.txt", blob(rng, 500, "text"))
    v.file("/links/dir/inner.txt", blob(rng, 300, "text"))
    L = v.letter

    def link(name, cmd, kind, sub, printed, flags, isdir=False):
        v.run(cmd)
        v.add(name, "symlink", None, expect="unsupported:reparse", link=printed, reparse={
            "kind": kind, "substituteName": sub, "printName": printed, "flags": flags})
    link("/links/sym-rel", f'mklink "{L}:\\links\\sym-rel" target.txt', "symlink-file", "target.txt", "target.txt", 1)
    link("/links/sym-abs", f'mklink "{L}:\\links\\sym-abs" "{L}:\\links\\target.txt"', "symlink-file",
         f"\\??\\{L}:\\links\\target.txt", f"{L}:\\links\\target.txt", 0)
    link("/links/dsym", f'mklink /D "{L}:\\links\\dsym" dir', "symlink-dir", "dir", "dir", 1)
    link("/links/junction", f'mklink /J "{L}:\\links\\junction" "{L}:\\links\\dir"', "junction",
         f"\\??\\{L}:\\links\\dir", f"{L}:\\links\\dir", 0)
    v.run(f'mklink /H "{L}:\\links\\hard" "{L}:\\links\\target.txt" >nul')
    vols.append(v)

    # compressed (LZNT1 written by Windows)
    v = Vol("compressed", "WIN-COMP", next(letters), payload)
    v.mkdir("/comp")
    v.file("/comp/text.txt", blob(rng, 300000, "text"))
    v.file("/comp/random.bin", blob(rng, 100000))
    v.file("/comp/small.txt", blob(rng, 900, "text"))
    v.file("/comp/mixed.bin", blob(rng, 30000, "text") + blob(rng, 30000) + blob(rng, 30000, "text"))
    v.run(f'compact /c /i /s:{v.letter}:\\comp')
    vols.append(v)

    # sparse
    v = Vol("sparse", "WIN-SPARSE", next(letters), payload)
    v.mkdir("/sp")
    base = blob(rng, 400000)
    v.cmds.append(f'copy /b "{payload.put(base)}" "{v.path("/sp/holes.bin")}" >nul')
    z = bytearray(base)
    z[65536:65536 + 131072] = bytes(131072)
    z[262144:262144 + 8192] = bytes(8192)
    v.run(f'fsutil sparse setflag "{v.path("/sp/holes.bin")}"')
    v.run(f'fsutil file setzerodata offset=65536 length=131072 "{v.path("/sp/holes.bin")}"')
    v.run(f'fsutil file setzerodata offset=262144 length=8192 "{v.path("/sp/holes.bin")}"')
    v.add("/sp/holes.bin", "file", bytes(z))
    v.run(f'fsutil file createnew "{v.path("/sp/all-hole.bin")}" 1048576')
    v.run(f'fsutil sparse setflag "{v.path("/sp/all-hole.bin")}"')
    v.run(f'fsutil file setzerodata offset=0 length=1048576 "{v.path("/sp/all-hole.bin")}"')
    v.add("/sp/all-hole.bin", "file", bytes(1048576))
    small = blob(rng, 100000)
    v.cmds.append(f'copy /b "{payload.put(small)}" "{v.path("/sp/extended.bin")}" >nul')
    v.run(f'fsutil file seteof "{v.path("/sp/extended.bin")}" 1000000')
    v.add("/sp/extended.bin", "file", small + bytes(1000000 - len(small)))
    vols.append(v)

    # attrlist: more names or streams than one 1 KiB record holds
    v = Vol("attrlist", "WIN-ATTRLIST", next(letters), payload)
    v.mkdir("/al")
    target = blob(rng, 5000, "text")
    v.file("/al/target.txt", target)
    v.run(f'for /L %%i in (1,1,300) do mklink /H "{v.letter}:\\al\\hardlink_with_a_rather_long_name_%%i.txt" "{v.letter}:\\al\\target.txt" >nul')
    for i in range(1, 301):
        v.add(f"/al/hardlink_with_a_rather_long_name_{i}.txt", "hardlink", target, link="/al/target.txt")
    v.cmds.append(f'copy /b "{payload.put(b"base")}" "{v.path("/al/streams.txt")}" >nul')
    v.run(f'for /L %%i in (1,1,100) do >"{v.letter}:\\al\\streams.txt:s%%i" echo %%i')
    v.add("/al/streams.txt", "file", b"base", streams={f"s{i}": f"{i}\r\n".encode() for i in range(1, 101)})
    vols.append(v)

    # fragmented: free every other small file, then write a file that has to use the holes
    v = Vol("fragmented", "WIN-FRAG", next(letters), payload)
    small = blob(rng, 8192)
    sp = payload.put(small)
    v.mkdir("/f")
    v.run(f'for /L %%i in (1,1,600) do copy /b "{sp}" "{v.letter}:\\f\\s%%i.bin" >nul')
    v.run(f'for /L %%i in (1,2,600) do del "{v.letter}:\\f\\s%%i.bin"')
    big = blob(rng, 3 * MB)
    v.file("/f/big.bin", big)
    for i in range(2, 601, 2):
        v.add(f"/f/s{i}.bin", "file", small)
    vols.append(v)

    # deleted
    v = Vol("deleted", "WIN-DELETED", next(letters), payload)
    v.mkdir("/del")
    keep = {}
    for i in range(10):
        data = blob(rng, 200 + 700 * i)
        v.cmds.append(f'copy /b "{payload.put(data)}" "{v.path(f"/del/f{i}.txt")}" >nul')
        if i % 2 == 0:
            keep[i] = data
        else:
            v.run(f'del "{v.path(f"/del/f{i}.txt")}"')
            v.add(f"/del/f{i}.txt", "deleted", data, expect="absent")
    for i, data in keep.items():
        v.add(f"/del/f{i}.txt", "file", data)
    reused = blob(rng, 3000)
    v.cmds.append(f'copy /b "{payload.put(blob(rng, 5000))}" "{v.path("/del/reused.txt")}" >nul')
    v.run(f'del "{v.path("/del/reused.txt")}"')
    v.cmds.append(f'copy /b "{payload.put(reused)}" "{v.path("/del/reused.txt")}" >nul')
    v.add("/del/reused.txt", "file", reused)
    vols.append(v)

    # dirty: the dirty bit is set by Windows itself
    v = Vol("dirty", "WIN-DIRTY", next(letters), payload)
    v.file("/c.txt", blob(rng, 40, "text"))
    v.mkdir("/docs")
    v.file("/docs/a.bin", blob(rng, 5000))
    v.dirty = True
    v.run(f'fsutil dirty set {v.letter}:')
    vols.append(v)
    return log, vols


def fix_hardlink(vols):
    for v in vols:
        if v.name == "links":
            t = v.entries["/links/target.txt"]
            v.entries["/links/hard"] = dict(t, path="/links/hard", type="hardlink", linkTarget="/links/target.txt")


RUN_CMD = r"""@echo off
setlocal enabledelayedexpansion
set S=%~dp0
set S=%S:~0,-1%
set LOGF=X:\run.log
echo Windows-written NTFS corpus > %LOGF%
fsutil fsinfo drives >> %LOGF% 2>&1
ver >> %LOGF% 2>&1
for %%t in (diskpart fsutil compact xcopy wpeutil chkdsk format) do if exist X:\Windows\System32\%%t.exe (echo found %%t >> %LOGF%) else (echo MISSING %%t >> %LOGF%)
echo --- diskpart >> %LOGF%
diskpart /s "%S%\diskpart.txt" >> %LOGF% 2>&1
echo --- format >> %LOGF%
call "%S%\format.cmd" >> %LOGF% 2>&1
echo --- files >> %LOGF%
call "%S%\files.cmd" >> %LOGF% 2>&1
echo --- chkdsk (read only) >> %LOGF%
%CHKDSK%
echo --- drivers >> %LOGF%
mkdir %LOGLETTER%:\bin >> %LOGF% 2>&1
for %%f in (drivers\ntfs.sys drivers\fastfat.sys drivers\refs.sys drivers\fs_rec.sys drivers\wof.sys drivers\fltmgr.sys chkdsk.exe autochk.exe fsutil.exe compact.exe untfs.dll ulib.dll ifsutil.dll fmifs.dll format.com diskpart.exe) do copy /y "X:\Windows\System32\%%f" "%LOGLETTER%:\bin\" >> %LOGF% 2>&1
dir X:\Windows\System32\drivers >> %LOGF% 2>&1
echo --- done >> %LOGF%
copy /y %LOGF% "%LOGLETTER%:\run.log" >nul
fsutil volume dismount %LOGLETTER%: >> X:\dismount.log 2>&1
%FINISH%
"""


def main(iso, work):
    os.makedirs(work, exist_ok=True)
    stage = os.path.join(work, "stage")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(os.path.join(stage, "payload"))
    payload = Payload(stage)
    log, vols = build_volumes(payload)
    fix_hardlink(vols)

    mount = subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-noverify", iso],
                           capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1].split("\t")[-1]
    try:
        for part in ("boot", "efi"):
            shutil.copytree(os.path.join(mount, part), os.path.join(stage, part))
        shutil.copy(os.path.join(mount, "bootmgr.efi"), stage)
        os.makedirs(os.path.join(stage, "sources"))
        shutil.copy(os.path.join(mount, "sources", "boot.wim"), os.path.join(stage, "sources"))
    finally:
        subprocess.run(["hdiutil", "detach", mount], capture_output=True)

    # diskpart script and file script
    dp = ["automount disable", "select disk 0", "clean", "convert gpt"]
    for v in [log] + vols:
        dp += [f"create partition primary size={v.size_mb}", f"assign letter={v.letter}"]
    dp += ["list volume", "exit"]
    files = ["@echo off", "chcp 65001 >nul", "setlocal"]
    for v in vols:
        files += [f"echo == {v.name}"] + v.cmds
    files += ["echo == dismount"]
    for v in vols:
        files.append(f"fsutil volume dismount {v.letter}:")
    for v in vols:
        if v.dirty:
            files.append(f"fsutil dirty set {v.letter}:")
    formats = ["@echo off"] + [
        f"format {v.letter}: /fs:ntfs /q /y /v:{v.label}" + (f" /a:{v.unit}" if v.unit else "") for v in [log] + vols]
    with open(os.path.join(stage, "payload", "format.cmd"), "w", newline="") as f:
        f.write("\r\n".join(formats) + "\r\n")
    with open(os.path.join(stage, "payload", "diskpart.txt"), "w") as f:
        f.write("\r\n".join(dp) + "\r\n")
    with open(os.path.join(stage, "payload", "files.cmd"), "w", encoding="utf-8", newline="") as f:
        f.write("\r\n".join(files) + "\r\n")
    chk = " & ".join(f"chkdsk {v.letter}: >> %LOGF% 2>&1" for v in vols if not v.dirty)
    run = RUN_CMD.replace("%CHKDSK%", chk).replace("%LOGLETTER%", log.letter).replace("%FINISH%", "wpeutil shutdown")
    with open(os.path.join(stage, "payload", "run.cmd"), "w", newline="") as f:
        f.write(run.replace("\n", "\r\n"))

    unattend = """<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd /c "for %i in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do @if exist %i:\\payload\\run.cmd call %i:\\payload\\run.cmd"</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"""
    with open(os.path.join(stage, "autounattend.xml"), "w", encoding="utf-8") as f:
        f.write(unattend)

    out = os.path.join(work, "oracle.iso")
    subprocess.run([MKISOFS, "-quiet", "-o", out, "-iso-level", "4", "-J", "-joliet-long", "-R", "-V", "NTFSORACLE",
                    "-eltorito-platform", "efi", "-b", "efi/microsoft/boot/efisys_noprompt.bin", "-no-emul-boot",
                    stage], check=True)

    layout = {"partitions": [{"name": v.name, "label": v.label, "letter": v.letter, "unit": v.unit,
                              "sizeMB": v.size_mb, "dirty": v.dirty} for v in [log] + vols]}
    for v in vols:
        layout[v.name] = sorted(v.entries.values(), key=lambda e: e["path"])
    with open(os.path.join(work, "expected.json"), "w") as f:
        json.dump(layout, f, indent=1)
    print("wrote", out, "and expected.json;", sum(len(v.entries) for v in vols), "expected entries")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
