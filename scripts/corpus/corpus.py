#!/usr/bin/env python3
"""Builds the NTFS reference corpus. Runs INSIDE the container (see build.sh).

For every image: mkntfs formats a sparse file, ntfs-3g mounts it through FUSE,
content is generated from a seeded PRNG and written, the volume is unmounted
and a manifest is written next to the image.

The manifest hashes are computed from the in-memory SOURCE bytes before they
are written to the mount. The image is never read back to produce a hash.
"""
import concurrent.futures as cf
import hashlib
import json
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import time
import unicodedata

WORK = os.environ.get("CORPUS_WORK", "/work")
OUT = os.environ.get("CORPUS_OUT", "/out")
os.environ["LC_ALL"] = "C.UTF-8"

FILE_ATTR_ARCHIVE = 0x20
FILE_ATTR_SPARSE = 0x200
FILE_ATTR_COMPRESSED = 0x800


def run(*cmd, check=True):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and r.returncode != 0:
        raise RuntimeError("%s failed (%d): %s" % (cmd, r.returncode, r.stdout.decode(errors="replace")))
    return r


def tool_version():
    out = run("ntfs-3g", "--version").stdout.decode().split()
    return "ntfs-3g " + out[1]


TOOL = None
KERNEL_TOOL = None


FLS_RE = re.compile(r"^(\S+)\s+(\*\s+)?(\d+)-\d+-\d+:\t(.*)$")
AL = "unsupported:attribute-list"


def label_attrlist(img_path, entries, mode="label"):
    """Derive the attribute-list label from the oracle (TSK istat): an entry gets it when its own
    base MFT record or that of any ancestor directory has an $ATTRIBUTE_LIST. Returns #changed."""
    out = run("fls", "-r", "-p", img_path).stdout.decode("utf-8", "replace")
    inode = {"/": 5}
    for line in out.splitlines():
        g = FLS_RE.match(line)
        if g and not g.group(2) and ":" not in g.group(4).rsplit("/", 1)[-1]:
            inode.setdefault("/" + g.group(4), int(g.group(3)))

    def chain(p):
        parts, cur = [], p
        while cur != "/":
            parts.append(cur)
            cur = cur.rsplit("/", 1)[0] or "/"
        return parts + ["/"]

    live = [e for e in entries if e["type"] != "deleted"]
    inos = set()
    for e in live:
        for q in chain(e["path"]):
            if q not in inode:
                raise RuntimeError("TSK cannot see %s" % q)
            inos.add(inode[q])

    def has(i):
        return i, b"$ATTRIBUTE_LIST" in run("istat", img_path, str(i)).stdout

    with cf.ThreadPoolExecutor(max_workers=4) as ex:
        al = dict(ex.map(has, sorted(inos)))
    changed = 0
    for e in live:
        hit = [q for q in chain(e["path"]) if al[inode[q]]]
        if mode == "field":  # keep expect as set by the builder, record the oracle result
            e["attributeList"] = bool(hit)
            changed += bool(hit)
            continue
        if not hit:
            continue
        why = "$ATTRIBUTE_LIST in MFT record of %s" % hit[0]
        if e["expect"] == "ok":
            e["expect"] = AL
            e["note"] = (e.get("note", "") + "; " if e.get("note") else "") + why
            changed += 1
        elif e["expect"] != AL:
            e["note"] = (e.get("note", "") + "; " if e.get("note") else "") + "also " + why
    return changed


# ---------------------------------------------------------------- content ---
def rng_for(img, key):
    h = hashlib.sha256(("macntfs-corpus:1:%s:%s" % (img, key)).encode("utf-8")).digest()
    return random.Random(int.from_bytes(h[:8], "big"))


def blob(img, key, n):
    """Incompressible bytes, stable for (img, key, n)."""
    return rng_for(img, key).randbytes(n)


WORDS = ("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi "
         "omicron pi rho sigma tau upsilon phi chi psi omega ntfs cluster runlist "
         "index record attribute stream sparse mft bitmap volume").split()


def text(img, key, n):
    """Compressible pseudo-text."""
    r = rng_for(img, key)
    out = bytearray()
    while len(out) < n:
        out += r.choice(WORDS).encode() + (b"\n" if r.random() < 0.08 else b" ")
    return bytes(out[:n])


def sha(b):
    return hashlib.sha256(b).hexdigest()


# ------------------------------------------------------------------- image ---
class Img:
    def __init__(self, name, sector=512, cluster=4096, size_mb=64, label=None, dest=None,
                 driver="ntfs-3g", legacy_header=False, al_mode="label", hibernated=None, dirty=False):
        self.dest = dest or OUT
        self.driver = driver          # "ntfs-3g" (FUSE) or "ntfs3" (Linux kernel driver)
        self.legacy_header = legacy_header  # omit "dirty" (only for the committed mini fixture)
        self.al_mode = al_mode        # "label": derive expect; "field": set entry["attributeList"]
        self.hibernated = hibernated
        self.dirty = dirty
        self.name = name
        self.sector = sector
        self.cluster = cluster
        self.size_mb = size_mb
        self.label = label or ("CORPUS-" + name.upper().replace("-", ""))[:32]
        self.path = "%s/%s.img" % (WORK, name)
        self.mnt = "%s/mnt-%s" % (WORK, name)
        self.entries = []

    def format(self):
        os.makedirs(WORK, exist_ok=True)
        if os.path.exists(self.path):
            os.remove(self.path)
        run("truncate", "-s", "%dM" % self.size_mb, self.path)
        run("mkntfs", "-F", "-Q", "-q", "-s", str(self.sector), "-c", str(self.cluster),
            "-L", self.label, self.path)
        return self

    def mount(self):
        os.makedirs(self.mnt, exist_ok=True)
        if self.driver == "ntfs3":
            run("mount", "-t", "ntfs3", "-o", "loop,iocharset=utf8,noatime", self.path, self.mnt)
        else:
            run("ntfs-3g", "-o", "rw,streams_interface=xattr,compression,noatime", self.path, self.mnt)
        return self

    def crash(self):
        """kill -9 the ntfs-3g daemon so the volume is never unmounted cleanly (dirty flag stays set)."""
        os.sync()
        pid = run("pgrep", "-f", "ntfs-3g.*" + self.mnt).stdout.decode().split()
        if not pid:
            raise RuntimeError("ntfs-3g process not found")
        for p in pid:
            run("kill", "-9", p, check=False)
        time.sleep(0.5)
        run("umount", "-l", self.mnt, check=False)
        time.sleep(0.5)

    def umount(self):
        os.sync()
        for i in range(10):
            r = run("umount", self.mnt, check=False)
            if r.returncode == 0:
                return
            time.sleep(0.5)
        raise RuntimeError("umount failed: " + r.stdout.decode())

    def __enter__(self):
        return self.mount()

    def __exit__(self, *a):
        self.umount()

    def p(self, path):
        return self.mnt + path

    # ---- recording
    def rec(self, path, typ, size=None, digest=None, expect="ok", link=None, streams=None, note=None, reparse=None):
        e = {"path": path, "type": typ, "size": size, "sha256": digest, "expect": expect,
             "linkTarget": link, "streams": streams or []}
        if note:
            e["note"] = note
        if reparse:
            e["reparse"] = reparse
        self.entries.append(e)

    def mkdir(self, path, streams=None):
        os.makedirs(self.p(path), exist_ok=True)
        sl = self.set_streams(path, streams)
        self.rec(path, "dir", streams=sl)

    def set_streams(self, path, streams):
        out = []
        for name, data in (streams or {}).items():
            os.setxattr(self.p(path), "user." + name, data)
            out.append({"name": name, "size": len(data), "sha256": sha(data)})
        return out

    def file(self, path, data, expect="ok", streams=None, typ="file", note=None, write=True):
        if write:
            with open(self.p(path), "wb") as f:
                f.write(data)
        sl = self.set_streams(path, streams)
        self.rec(path, typ, len(data), sha(data), expect, None, sl, note)

    def attrib(self, path, flags):
        os.setxattr(self.p(path), "system.ntfs_attrib_be", struct.pack(">I", flags),
                    follow_symlinks=False)

    def finish(self):
        self.relabeled = label_attrlist(self.path, self.entries, self.al_mode)
        header = {"schema": 1, "image": self.name + ".img", "tool": TOOL if self.driver == "ntfs-3g" else KERNEL_TOOL,
                  "sectorSize": self.sector, "clusterSize": self.cluster,
                  "volumeLabel": self.label}
        if not self.legacy_header:
            header["dirty"] = self.dirty
            if self.hibernated is not None:
                header["hibernated"] = self.hibernated
        ents = sorted(self.entries, key=lambda e: (e["path"], e["type"] == "deleted"))
        lines = ["{"]
        for k, v in header.items():
            lines.append(' "%s": %s,' % (k, json.dumps(v)))
        lines.append(' "entries": [')
        lines.append(",\n".join("  " + json.dumps(e) for e in ents))
        lines.append(" ]")
        lines.append("}")
        os.makedirs(self.dest, exist_ok=True)
        mpath = "%s/%s.manifest.json" % (self.dest, self.name)
        with open(mpath + ".tmp", "w") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(mpath + ".tmp", mpath)
        ipath = "%s/%s.img" % (self.dest, self.name)
        if os.path.exists(ipath):
            os.remove(ipath)
        run("cp", "--sparse=always", self.path, ipath)
        os.remove(self.path)
        return len(ents)


# ---------------------------------------------------------------- builders ---
def populate_basic(m, kernel=False):
    n = m.name
    for d in ["/docs", "/docs/nested", "/docs/nested/deeper", "/docs/nested/deeper/still",
              "/docs/nested/deeper/still/deeper", "/src", "/src/a", "/src/a/b", "/empty-dir",
              "/unicode", "/names"]:
        m.mkdir(d)
    sizes = [("empty.bin", 0), ("one.bin", 1), ("f500.bin", 500), ("f700.bin", 700),
             ("f4096.bin", 4096), ("f4097.bin", 4097), ("f100k.bin", 100 * 1024),
             ("f5m.bin", 5 * 1024 * 1024)]
    for fn, sz in sizes:
        m.file("/" + fn, blob(n, fn, sz))
    m.file("/docs/readme.txt", text(n, "readme", 3000))
    m.file("/docs/nested/notes.txt", text(n, "notes", 9000))
    m.file("/docs/nested/deeper/still/deeper/leaf.bin", blob(n, "leaf", 12345))
    m.file("/src/a/b/main.c", text(n, "main.c", 777))
    m.file("/src/a/b/zero-in-dir.bin", b"")
    # unicode: NFC and NFD forms are distinct names on NTFS
    nfc = unicodedata.normalize("NFC", "caf\u00e9.txt")
    nfd = unicodedata.normalize("NFD", "caf\u00e9.txt")
    assert nfc != nfd
    m.file("/unicode/" + nfc, text(n, "nfc", 600))
    m.file("/unicode/" + nfd, text(n, "nfd", 650))
    for i, nm in enumerate(["\u65e5\u672c\u8a9e.txt", "\u00dcn\u00efc\u00f6d\u00e9-\u0394.txt",
                            "\u041f\u0440\u0438\u0432\u0435\u0442.txt", "\U0001F600 emoji.txt",
                            "\u05e9\u05dc\u05d5\u05dd.txt"]):
        m.file("/unicode/" + nm, text(n, "uni%d" % i, 100 + 37 * i))
    # long names
    m.file("/names/" + "a" * 251 + ".txt", text(n, "long255", 400))
    m.file("/names/" + "\u6f22" * 85, text(n, "long85cjk", 401))
    # spaces and dots
    for i, nm in enumerate(["name with spaces.txt", "two  spaces  .txt", "a . b.txt", "..leading.dots",
                            ".hidden", "many.dots.in.name.tar.gz", "UPPER and lower.TXT",
                            "semi;colon,comma'quote.txt", "#hash&amp%pct.txt", "-dash", "tilde~1.txt",
                            "longfilename_here.txt", "LONGFI~1.TXT", "x"]):
        if kernel and nm in ("LONGFI~1.TXT",):
            continue  # the kernel driver may generate DOS names itself
        m.file("/names/" + nm, blob(n, "nm%d" % i, 50 + i * 13))


def b_basic(name, sector, cluster, mb):
    m = Img(name, sector, cluster, mb).format()
    with m:
        populate_basic(m)
    return m


def b_fragmented():
    m = Img("fragmented", 512, 4096, 40).format()
    n = m.name
    with m:
        m.mkdir("/frag")
        nfiles, chunk, rounds = 16, 3 * 4096, 40
        data = [blob(n, "frag%d" % i, chunk * rounds - 1000 * i) for i in range(nfiles)]
        hs = [open(m.p("/frag/f%02d.bin" % i), "wb", buffering=0) for i in range(nfiles)]
        for r in range(rounds):
            for i, h in enumerate(hs):
                h.write(data[i][r * chunk:(r + 1) * chunk])
        for h in hs:
            h.close()
        for i in range(nfiles):
            if i % 2 == 0:
                m.rec("/frag/f%02d.bin" % i, "file", len(data[i]), sha(data[i]))
            else:
                os.unlink(m.p("/frag/f%02d.bin" % i))
        # written after the deletions, interleaved with each other
        fd = [blob(n, "fill%d" % j, 2 * 1024 * 1024 + j * 4097) for j in range(4)]
        fh = [open(m.p("/frag/fill%d.bin" % j), "wb", buffering=0) for j in range(4)]
        for r in range(0, len(fd[3]), 65536):
            for j, h in enumerate(fh):
                h.write(fd[j][r:r + 65536])
        for h in fh:
            h.close()
        for j in range(4):
            m.rec("/frag/fill%d.bin" % j, "file", len(fd[j]), sha(fd[j]))
        # appended in small pieces next to other appenders
        sm = [open(m.p("/frag/app%d.bin" % i), "wb", buffering=0) for i in range(3)]
        ad = [blob(n, "app%d" % i, 300 * 1000) for i in range(3)]
        for r in range(0, 300 * 1000, 5000):
            for i, h in enumerate(sm):
                h.write(ad[i][r:r + 5000])
        for h in sm:
            h.close()
        for i in range(3):
            m.rec("/frag/app%d.bin" % i, "file", len(ad[i]), sha(ad[i]))
    return m


def b_sparse():
    m = Img("sparse", 512, 4096, 40).format()
    n = m.name

    def sparse(path, size, chunks):
        content = bytearray(size)
        for off, b in chunks:
            content[off:off + len(b)] = b
        open(m.p(path), "wb").close()
        m.attrib(path, FILE_ATTR_ARCHIVE | FILE_ATTR_SPARSE)
        fd = os.open(m.p(path), os.O_WRONLY)
        os.ftruncate(fd, size)
        for off, b in chunks:
            os.pwrite(fd, b, off)
        os.close(fd)
        m.rec(path, "file", size, sha(bytes(content)))

    with m:
        m.mkdir("/sp")
        sparse("/sp/hole-start.bin", 3 * 1024 * 1024, [(3 * 1024 * 1024 - 4096, blob(n, "hs", 4096))])
        sparse("/sp/hole-middle.bin", 4 * 1024 * 1024,
               [(0, blob(n, "hm0", 8192)), (2 * 1024 * 1024 + 17, blob(n, "hm1", 4096)),
                (4 * 1024 * 1024 - 100, blob(n, "hm2", 100))])
        sparse("/sp/all-hole.bin", 1024 * 1024, [])
        sparse("/sp/hole-then-tail.bin", 1000000, [(999000, blob(n, "ht", 1000))])
        r = rng_for(n, "multi")
        chunks, used = [], []
        for i in range(40):
            off = r.randrange(0, 16 * 1024 * 1024 - 3000)
            ln = r.randrange(1, 3000)
            chunks.append((off, blob(n, "mc%d" % i, ln)))
        # later chunks overwrite earlier overlapping ones in `content` AND in the file in the same order
        sparse("/sp/hole-multi.bin", 16 * 1024 * 1024, chunks)
        m.file("/sp/dense.bin", blob(n, "dense", 300 * 1024))
    return m


def b_compressed():
    m = Img("compressed", 512, 4096, 24).format()
    n = m.name
    with m:
        m.mkdir("/comp")
        # ntfs-3g only creates compressed data in a directory that carries the compressed flag
        # (files created there inherit it); setting the flag on a file directly is ignored.
        m.attrib("/comp", 0x10 | FILE_ATTR_COMPRESSED)
        m.mkdir("/plain")

        def comp(path, data):
            with open(m.p(path), "wb") as f:
                f.write(data)
            m.rec(path, "file", len(data), sha(data), "unsupported:compression")

        comp("/comp/text200k.txt", text(n, "t200k", 200 * 1024))
        comp("/comp/text1m.txt", text(n, "t1m", 1024 * 1024))
        comp("/comp/pattern64k.bin", (b"ABCDEFGH" * 8192))
        comp("/comp/random128k.bin", blob(n, "r128k", 128 * 1024))
        comp("/comp/half.bin", bytes(96 * 1024) + blob(n, "half", 96 * 1024))
        comp("/comp/zeros256k.bin", bytes(256 * 1024))
        comp("/comp/odd-size.txt", text(n, "odd", 150001))
        m.file("/plain/plain.bin", blob(n, "plain", 150 * 1024))  # uncompressed control
        m.file("/plain/plain-small.txt", text(n, "plain-small", 1200))
    return m


def b_ads():
    m = Img("ads", 512, 4096, 16).format()
    n = m.name
    with m:
        m.mkdir("/ads")
        m.file("/ads/one-stream.txt", text(n, "os", 1000),
               streams={"s1": b"x"})
        m.file("/ads/multi.txt", text(n, "mu", 5000),
               streams={"alpha": blob(n, "a", 100), "beta": blob(n, "b", 3000),
                        "gamma": blob(n, "g", 40000), "tiny": b"Z"})
        m.file("/ads/empty-default.txt", b"", streams={"data": text(n, "ed", 777)})
        m.file("/ads/big-default.bin", blob(n, "bd", 200 * 1024),
               streams={"meta": text(n, "meta", 60000), "small": b"hello"})
        m.file("/ads/unicode-stream.txt", b"default", streams={"\u30b9\u30c8\u30ea\u30fc\u30e0": b"jp stream"})
        m.file("/ads/zero-len-stream.txt", b"has empty stream", streams={"empty": b""})
        m.mkdir("/ads/dir-with-stream", streams={"dirstream": text(n, "ds", 2500)})
        m.file("/ads/dir-with-stream/inner.txt", text(n, "inner", 300))
    return m


def reparse_symlink(target, relative=True):
    sub = target.encode("utf-16le")
    data = struct.pack("<HHHHI", 0, len(sub), len(sub), len(sub), 1 if relative else 0) + sub + sub
    return struct.pack("<IHH", 0xA000000C, len(data), 0) + data


def reparse_junction(target):
    sub = ("\\??\\" + target).encode("utf-16le")
    pr = target.encode("utf-16le")
    data = struct.pack("<HHHH", 0, len(sub), len(sub) + 2, len(pr)) + sub + b"\0\0" + pr + b"\0\0"
    return struct.pack("<IHH", 0xA0000003, len(data), 0) + data


def b_links():
    m = Img("links", 512, 4096, 16).format()
    n = m.name
    with m:
        for d in ["/hl", "/hl/sub", "/other", "/links"]:
            m.mkdir(d)
        data = text(n, "hl", 3000)
        m.file("/hl/a.txt", data, typ="hardlink")
        first = "/hl/a.txt"
        for p in ["/hl/b.txt", "/hl/sub/c.txt", "/other/d.txt"]:
            os.link(m.p(first), m.p(p))
            m.rec(p, "hardlink", len(data), sha(data), link=first)
        m.entries[-4]["linkTarget"] = first
        # small resident hardlinked file
        data2 = b"tiny hardlinked"
        m.file("/hl/tiny1.txt", data2, typ="hardlink")
        os.link(m.p("/hl/tiny1.txt"), m.p("/other/tiny2.txt"))
        m.rec("/other/tiny2.txt", "hardlink", len(data2), sha(data2), link="/hl/tiny1.txt")
        m.entries[-2]["linkTarget"] = "/hl/tiny1.txt"
        m.file("/links/target.txt", text(n, "tgt", 500))
        # ntfs-3g default symlinks: Interix style = SYSTEM file with IntxLNK payload in $DATA
        for nm, tgt in [("sym-file", "target.txt"), ("sym-up", "../hl/a.txt"), ("sym-abs", "/hl/a.txt"),
                        ("sym-dangling", "does/not/exist")]:
            os.symlink(tgt, m.p("/links/" + nm))
            raw = b"IntxLNK\x01" + tgt.encode("utf-16le")
            m.rec("/links/" + nm, "symlink", len(raw), sha(raw), "ok", tgt, [],
                  "ntfs-3g Interix-style symlink: SYSTEM file whose default stream is the IntxLNK payload, no reparse point")
        # real reparse points (crafted through system.ntfs_reparse_data)
        open(m.p("/links/rp-symlink-file"), "wb").close()
        os.setxattr(m.p("/links/rp-symlink-file"), "system.ntfs_reparse_data",
                    reparse_symlink("target.txt"), follow_symlinks=False)
        m.rec("/links/rp-symlink-file", "symlink", None, None, "unsupported:reparse", "target.txt", [],
              "IO_REPARSE_TAG_SYMLINK (0xA000000C), relative",
              {"kind": "symlink-file", "substituteName": "target.txt", "printName": "target.txt", "flags": 1})
        os.mkdir(m.p("/links/rp-symlink-dir"))
        os.setxattr(m.p("/links/rp-symlink-dir"), "system.ntfs_reparse_data",
                    reparse_symlink("../hl"), follow_symlinks=False)
        m.rec("/links/rp-symlink-dir", "symlink", None, None, "unsupported:reparse", "../hl", [],
              "IO_REPARSE_TAG_SYMLINK (0xA000000C) on a directory, relative",
              {"kind": "symlink-dir", "substituteName": "../hl", "printName": "../hl", "flags": 1})
        os.mkdir(m.p("/links/rp-junction"))
        os.setxattr(m.p("/links/rp-junction"), "system.ntfs_reparse_data",
                    reparse_junction("C:\\target"), follow_symlinks=False)
        m.rec("/links/rp-junction", "symlink", None, None, "unsupported:reparse", "C:\\target", [],
              "IO_REPARSE_TAG_MOUNT_POINT (0xA0000003) junction, print name C:\\target",
              {"kind": "junction", "substituteName": "\\??\\C:\\target", "printName": "C:\\target", "flags": 0})
    return m


def b_manydirs():
    m = Img("manydirs", 512, 4096, 48).format()
    n = m.name
    with m:
        m.mkdir("/big")
        sizes = [0, 10, 100, 300, 700, 1500]
        for i in range(3500):
            sz = sizes[i % len(sizes)]
            m.file("/big/f%05d.txt" % i, blob(n, "big%d" % i, sz))
        m.mkdir("/big/sub1")
        for i in range(1500):
            m.file("/big/sub1/item-%05d-%s.dat" % (i, "padding" * 3), blob(n, "s1_%d" % i, 20 + i % 90))
        m.mkdir("/big/sub1/sub2")
        for i in range(25):
            m.file("/big/sub1/sub2/leaf%02d.txt" % i, text(n, "leaf%d" % i, 100 + i))
        m.mkdir("/dirs")
        for i in range(300):
            d = "/dirs/d%03d" % i
            m.mkdir(d)
            m.file(d + "/only.txt", text(n, "do%d" % i, 40 + i))
    return m


def b_attrlist():
    m = Img("attrlist", 512, 4096, 40).format()
    n = m.name
    AL = "unsupported:attribute-list"
    with m:
        m.mkdir("/al")
        m.mkdir("/al/links")
        # (1) one inode with 80 long hard-link names: $FILE_NAME attributes overflow the record
        data = blob(n, "many-links", 2000)
        first = "/al/many-links.bin"
        m.file(first, data, AL, typ="hardlink")
        for i in range(80):
            p = "/al/links/link-%03d-with-a-fairly-long-name-to-fill-the-mft-record-aaaaaaaaaaaaaaaaaaaaaaaa.bin" % i
            os.link(m.p(first), m.p(p))
            m.rec(p, "hardlink", len(data), sha(data), AL, first)
        m.entries[-81]["linkTarget"] = first
        # (2) very fragmented files: the runlist does not fit in the base record
        chunk, rounds = 4096, 800
        d = [blob(n, "vf%d" % i, chunk * rounds) for i in range(3)]
        hs = [open(m.p("/al/frag%d.bin" % i), "wb", buffering=0) for i in range(3)]
        for r in range(rounds):
            for i, h in enumerate(hs):
                h.write(d[i][r * chunk:(r + 1) * chunk])
        for h in hs:
            h.close()
        for i in range(3):
            m.rec("/al/frag%d.bin" % i, "file", len(d[i]), sha(d[i]), AL)
        # (3) 40 alternate data streams: the attributes spill into extension records
        streams = {"st%02d" % i: blob(n, "st%d" % i, 120 + i) for i in range(40)}
        m.file("/al/many-streams.bin", blob(n, "ms", 5000), AL, streams=streams)
        # control: a plain file in the same directory
        m.file("/al/plain.txt", text(n, "al-plain", 1000))
    return m


def b_deleted():
    m = Img("deleted", 512, 4096, 24).format()
    n = m.name
    with m:
        m.mkdir("/del")
        for i in range(6):
            m.file("/del/keep%d.txt" % i, text(n, "keep%d" % i, 200 + i * 900))
        gone = [("gone-small.txt", 120), ("gone-mid.bin", 5000), ("gone-big.bin", 600 * 1024),
                ("gone-empty.bin", 0), ("gone-" + "u" * 40 + "\u00e9.txt", 333)]
        for fn, sz in gone:
            d = blob(n, fn, sz)
            with open(m.p("/del/" + fn), "wb") as f:
                f.write(d)
            os.unlink(m.p("/del/" + fn))
            m.rec("/del/" + fn, "deleted", sz, sha(d), "absent")
        # deleted directory tree
        os.makedirs(m.p("/del/gonedir/inner"))
        for fn in ["gonedir/a.txt", "gonedir/inner/b.txt"]:
            d = text(n, fn, 800)
            with open(m.p("/del/" + fn), "wb") as f:
                f.write(d)
            m.rec("/del/" + fn, "deleted", len(d), sha(d), "absent")
        shutil.rmtree(m.p("/del/gonedir"))
        m.rec("/del/gonedir/inner", "deleted", None, None, "absent")
        m.rec("/del/gonedir", "deleted", None, None, "absent")
        # deleted, then a different file created under the same name
        old = text(n, "reused-old", 4000)
        with open(m.p("/del/reused.txt"), "wb") as f:
            f.write(old)
        os.unlink(m.p("/del/reused.txt"))
        m.rec("/del/reused.txt", "deleted", len(old), sha(old), "absent")
        m.file("/del/reused.txt", text(n, "reused-new", 2500))
    return m


def b_empty():
    m = Img("empty", 512, 4096, 8).format()
    return m


def b_mini():
    """Small committed fixture (Tests/Fixtures/mini.*); only built when named explicitly."""
    m = Img("mini", 512, 4096, 10, label="MINI", dest=os.environ.get("CORPUS_FIXTURES", "/fixtures"), legacy_header=True).format()
    n = m.name
    with m:
        m.file("/small.txt", b"hello")
        m.file("/big.bin", blob(n, "big", 20000))
        m.file("/empty.bin", b"")
        m.mkdir("/dir")
        m.file("/dir/nested.txt", text(n, "nested", 700))
        m.mkdir("/unicode")
        m.file("/unicode/" + unicodedata.normalize("NFC", "caf\u00e9.txt"), text(n, "nfc", 600))
        m.file("/unicode/" + unicodedata.normalize("NFD", "caf\u00e9.txt"), text(n, "nfd", 650))
        m.mkdir("/many")
        for i in range(150):
            m.file("/many/file-%03d-with-a-long-name-to-fill-index-blocks.txt" % i,
                   text(n, "many%d" % i, 50 + (i * 7) % 251))
    return m


def al_entries(img, path):
    """(attribute-list rows [(type, mft, vcn)], istat text) for `path`, from TSK istat."""
    ino = run("ifind", "-n", path, img).stdout.decode().strip()
    t = run("istat", img, ino).stdout.decode("utf-8", "replace")
    rows = []
    for l in t.splitlines():
        g = re.match(r"Type: (\d+)-\d+ \tMFT Entry: (\d+) \tVCN: (\d+)", l)
        if g:
            rows.append(tuple(int(x) for x in g.groups()))
    return rows, t


def check_mini_attrlist(img):
    """Fail the build unless the fixture really contains what it advertises (evidence from TSK istat)."""
    bad = []
    rows, t = al_entries(img, "/ds")
    runs = 0
    for l in t.splitlines():
        if l.startswith("Type: $INDEX_ALLOCATION"):
            blocks = int(re.search(r"size: (\d+)", l).group(1)) // 4096
            nums = [int(x) for x in t.split(l, 1)[1].split("\nType:", 1)[0].split()]
            runs = 1 + sum(1 for a, b in zip(nums, nums[1:]) if b != a + 1)
    if not rows or runs < 2:
        bad.append("/ds: need $ATTRIBUTE_LIST and >=2 index runs (AL=%s runs=%d)" % (bool(rows), runs))
    rows, t = al_entries(img, "/de")
    if not any(r[0] == 160 and r[2] > 0 for r in rows):
        bad.append("/de: $INDEX_ALLOCATION not split into extension records: %s" % rows)
    rows, t = al_entries(img, "/links/" + "link-00-".ljust(90, "z"))
    if sum(1 for r in rows if r[0] == 48) < 40 or not any(r[0] == 48 and r[1] != rows[0][1] for r in rows):
        bad.append("link file: $FILE_NAME not overflowing: %s" % rows)
    for f in ("/frag/f0.bin", "/frag/f1.bin", "/frag/f2.bin"):
        rows, t = al_entries(img, f)
        if not any(r[0] == 128 and r[2] > 0 for r in rows):
            bad.append("%s: no $DATA extent with VCN>0: %s" % (f, rows))
    for f in ("/control", "/control/plain.txt", "/control/big.bin", "/control/dir", "/control/dir/inner.txt"):
        if al_entries(img, f)[0]:
            bad.append("%s unexpectedly has an attribute list" % f)
    if bad:
        raise RuntimeError("mini-attrlist does not meet its contract: " + "; ".join(bad))


def b_mini_attrlist():
    """Committed fixture with real attribute lists; every entry is expect "ok" and carries the
    TSK-derived "attributeList" boolean. Only built when named explicitly."""
    m = Img("mini-attrlist", 512, 4096, 16, label="MINIAL", dest=os.environ.get("CORPUS_FIXTURES", "/fixtures"),
            al_mode="field").format()
    n = m.name
    with m:
        # (a1) smallest directory with an $ATTRIBUTE_LIST and 2 index blocks (long names)
        m.mkdir("/ds")
        for i in range(9):
            m.file("/ds/" + ("n%03d-" % i).ljust(200, "x"), text(n, "ds%d" % i, 5000))
        # (a2) directory like manydirs /big: $INDEX_ALLOCATION itself split over extension records
        m.mkdir("/de")
        for i in range(1200):
            m.file("/de/" + ("e%04d-" % i).ljust(120, "y"), text(n, "de%d" % i, 1000))
        # (b) one inode with 45 hard-link names (the $FILE_NAME attributes overflow the record)
        m.mkdir("/links")
        data = text(n, "hl", 2000)
        first = "/links/" + ("link-00-").ljust(90, "z")
        m.file(first, data, typ="hardlink")
        m.entries[-1]["linkTarget"] = first
        for i in range(1, 45):
            p = "/links/" + ("link-%02d-" % i).ljust(90, "z")
            os.link(m.p(first), m.p(p))
            m.rec(p, "hardlink", len(data), sha(data), link=first)
        # (c) heavily fragmented files: $DATA runlist continues in extension records
        m.mkdir("/frag")
        chunk, rounds = 4096, 500
        d = [text(n, "fr%d" % i, chunk * rounds) for i in range(3)]
        hs = [open(m.p("/frag/f%d.bin" % i), "wb", buffering=0) for i in range(3)]
        for r in range(rounds):
            for i, h in enumerate(hs):
                h.write(d[i][r * chunk:(r + 1) * chunk])
        for h in hs:
            h.close()
        for i in range(3):
            m.rec("/frag/f%d.bin" % i, "file", len(d[i]), sha(d[i]))
        # (d) controls without an attribute list
        m.mkdir("/control")
        m.mkdir("/control/dir")
        m.file("/control/plain.txt", text(n, "cp", 500))
        m.file("/control/big.bin", text(n, "cb", 30000))
        m.file("/control/dir/inner.txt", text(n, "ci", 300))
    check_mini_attrlist(m.path)
    return m


def hib_builder(name, hibernated):
    m = Img(name, 512, 4096, 16, hibernated=hibernated).format()
    with m:
        head = (b"hibr" if hibernated else bytes(4)) + bytes(4092)
        body = blob("hib", "body", 4 * 1024 * 1024 - 4096)  # same bytes in both images
        m.file("/hiberfil.sys", head + body)
        m.file("/small.txt", text(name, "small", 300))
        m.mkdir("/dir")
        m.file("/dir/note.txt", text(name, "note", 900))
    return m


def set_dirty_flag(path):
    """Set VOLUME_IS_DIRTY (0x0001) in $Volume/$VOLUME_INFORMATION by writing the image directly.
    Neither ntfs-3g 2022.10.3 nor the kernel ntfs3 driver leaves the flag set after kill -9 /
    a snapshot of a mounted volume, so the bit is set by hand (record 3 = $Volume)."""
    with open(path, "r+b") as f:
        boot = f.read(512)
        sec = struct.unpack_from("<H", boot, 11)[0]
        clu = boot[13] * sec
        mft = struct.unpack_from("<q", boot, 0x30)[0] * clu
        c = struct.unpack_from("<b", boot, 0x40)[0]
        rec = c * clu if c > 0 else 1 << -c
        f.seek(mft + 3 * rec)
        r = bytearray(f.read(rec))
        assert r[:4] == b"FILE"
        off = struct.unpack_from("<H", r, 0x14)[0]
        while struct.unpack_from("<I", r, off)[0] != 0xFFFFFFFF:
            typ, ln = struct.unpack_from("<II", r, off)
            if typ == 0x70:
                voff = off + struct.unpack_from("<H", r, off + 0x14)[0]
                fpos = voff + 10
                assert fpos % 512 not in (510, 511), "flags overlap the fixup slot"
                flags = struct.unpack_from("<H", r, fpos)[0] | 0x0001
                struct.pack_into("<H", r, fpos, flags)
                mirr = struct.unpack_from("<q", boot, 0x38)[0] * clu  # $MFTMirr must stay identical
                for base in (mft, mirr):
                    f.seek(base + 3 * rec)
                    f.write(r)
                return
            off += ln
        raise RuntimeError("$VOLUME_INFORMATION not found")


def b_dirty():
    m = Img("dirty", 512, 4096, 16, dirty=True).format()
    n = m.name
    m.mount()
    m.mkdir("/docs")
    m.file("/docs/a.txt", text(n, "a", 1500))
    m.file("/docs/b.bin", blob(n, "b", 100000))
    m.file("/c.txt", text(n, "c", 40))
    m.mkdir("/many")
    for i in range(40):
        m.file("/many/f%02d.txt" % i, blob(n, "m%d" % i, 30 + i))
    m.crash()  # no clean unmount
    set_dirty_flag(m.path)
    return m


def kernel_builder(name, many):
    m = Img(name, 512, 4096, 48 if many else 32, driver="ntfs3").format()
    with m:
        if many:
            m.mkdir("/many")
            for i in range(1500):
                m.file("/many/file-%04d-with-a-long-name.txt" % i, blob(m.name, "k%d" % i, 20 + (i * 37) % 900))
        else:
            populate_basic(m, kernel=True)
    return m


# ------------------------------------------------------------------- main ---
BUILDERS = [
    ("basic-512", lambda: b_basic("basic-512", 512, 4096, 32)),
    ("basic-4kn", lambda: b_basic("basic-4kn", 4096, 4096, 32)),
    ("cluster-512", lambda: b_basic("cluster-512", 512, 512, 32)),
    ("cluster-64k", lambda: b_basic("cluster-64k", 512, 65536, 48)),
    ("fragmented", b_fragmented),
    ("sparse", b_sparse),
    ("compressed", b_compressed),
    ("ads", b_ads),
    ("links", b_links),
    ("manydirs", b_manydirs),
    ("attrlist", b_attrlist),
    ("deleted", b_deleted),
    ("empty", b_empty),
    ("dirty", b_dirty),
    ("hibernated", lambda: hib_builder("hibernated", True)),
    ("hiberfil-woken", lambda: hib_builder("hiberfil-woken", False)),
    ("k-basic", lambda: kernel_builder("k-basic", False)),
    ("k-many", lambda: kernel_builder("k-many", True)),
]
EXPLICIT_ONLY = [("mini", b_mini), ("mini-attrlist", b_mini_attrlist)]  # not part of the default build


def main():
    global TOOL
    global KERNEL_TOOL
    TOOL = tool_version()
    mk = run("mkntfs", "--version").stdout.decode().split("mkntfs v")[1].split()[0]
    KERNEL_TOOL = "linux ntfs3 %s + mkntfs %s" % (os.uname().release, mk)
    have_ntfs3 = "ntfs3" in open("/proc/filesystems").read().split()
    want = sys.argv[1:]
    allb = BUILDERS + EXPLICIT_ONLY
    names = [b[0] for b in allb]
    for w in want:
        if w not in names:
            sys.exit("unknown image %r; known: %s" % (w, " ".join(names)))
    failed = []
    for name, fn in allb:
        if (want and name not in want) or (not want and (name, fn) in EXPLICIT_ONLY):
            continue
        t0 = time.time()
        if name.startswith("k-") and not have_ntfs3:
            print("SKIPPED %-12s ntfs3 kernel driver not available in this VM" % name, flush=True)
            if want:
                failed.append(name)
            continue
        try:
            m = fn()
            cnt = m.finish()
            print("built %-12s %5d manifest entries  %5.1fs  relabeled to attribute-list: %d" % (name, cnt, time.time() - t0, m.relabeled), flush=True)
        except Exception as ex:  # keep going, report at the end
            failed.append(name)
            print("FAILED %-12s %s" % (name, ex), flush=True)
            run("umount", "%s/mnt-%s" % (WORK, name), check=False)
    if failed:
        sys.exit("failed images: " + " ".join(failed))


if __name__ == "__main__":
    main()
