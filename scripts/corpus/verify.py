#!/usr/bin/env python3
"""Cross-checks every manifest against its image with two independent readers.

Readers: ntfs-3g tools (ntfscat, ntfsls) and The Sleuth Kit (ifind, icat, fls, istat).
The manifest hashes come from the SOURCE content; any disagreement means the
manifest or the image is wrong and has to be fixed, not hidden.

Runs inside the container. Usage: verify.py [corpus-dir] [image-name ...]
"""
import concurrent.futures as cf
import hashlib
import json
import os
import re
import struct
import subprocess
import sys

os.environ["LC_ALL"] = "C.UTF-8"
D = sys.argv[1] if len(sys.argv) > 1 else "/out"
ONLY = sys.argv[2:]


def run(cmd):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.returncode, r.stdout, r.stderr


def sha(b):
    return hashlib.sha256(b).hexdigest()


def parent(p):
    return p.rsplit("/", 1)[0] or "/"


def base(p):
    return p.rsplit("/", 1)[1]


FLS_RE = re.compile(r"^(\S+)\s+(\*\s+)?(\d+-\d+-\d+):\t(.*)$")


def fls_map(img):
    """{path: [(inode-type-id, deleted)]} from `fls -r -p`; paths get a leading slash."""
    rc, out, err = run(["fls", "-r", "-p", img])
    if rc != 0:
        raise RuntimeError("fls failed: " + err.decode(errors="replace"))
    m = {}
    for line in out.decode("utf-8", "replace").splitlines():
        g = FLS_RE.match(line)
        if g:
            m.setdefault("/" + g.group(4), []).append((g.group(3), bool(g.group(2))))
    return m


def runs_of(istat_text):
    """Number of runs in the unnamed $DATA attribute (sparse holes are separate runs)."""
    lines = istat_text.splitlines()
    for i, l in enumerate(lines):
        if l.startswith("Type: $DATA (128-") and "Name: N/A" in l and "Non-Resident" in l:
            nums = []
            for l2 in lines[i + 1:]:
                if l2.startswith("Type:") or not l2.strip():
                    break
                nums += [int(x) for x in l2.split()]
            runs, prev = 0, None
            for n in nums:
                if prev is None or n == 0 or prev == 0 or n != prev + 1:
                    runs += 1
                prev = n
            return runs
    return 0


AL_ROW = re.compile(r"Type: (\d+)-\d+ \tMFT Entry: (\d+) \tVCN: (\d+)")


def al_rows(text):
    return [tuple(int(x) for x in m.groups()) for m in map(AL_ROW.match, text.splitlines()) if m]


class Checker:
    def __init__(self, mpath):
        self.mf = json.load(open(mpath))
        self.name = self.mf["image"][:-4]
        self.img = os.path.join(os.path.dirname(mpath), self.mf["image"])
        self.bad = []
        self.n = {"ntfscat": [0, 0], "tsk": [0, 0], "ntfsls": [0, 0], "fls": [0, 0], "features": [0, 0]}
        self.istat_cache = {}

    def ok(self, k):
        self.n[k][0] += 1

    def fail(self, k, msg):
        self.n[k][1] += 1
        self.bad.append("[%s] %s" % (k, msg))

    # ---- readers
    def ntfscat(self, path, stream=None):
        cmd = ["ntfscat", "-f", "-q"] + (["-n", stream] if stream else []) + [self.img, path]
        rc, out, err = run(cmd)
        return rc, out, err

    def ifind(self, path):
        rc, out, err = run(["ifind", "-n", path, self.img])
        t = out.decode().strip()
        return t if rc == 0 and t.isdigit() else None

    def icat(self, inode):
        rc, out, err = run(["icat", self.img, inode])
        return rc, out

    def istat(self, inode):
        if inode not in self.istat_cache:
            rc, out, err = run(["istat", self.img, inode])
            self.istat_cache[inode] = out.decode("utf-8", "replace")
        return self.istat_cache[inode]

    # ---- per entry
    def check_content(self, e, fm):
        p = e["path"]
        want = e["sha256"]
        rc, out, err = self.ntfscat(p)
        if rc != 0:
            self.fail("ntfscat", "%s: ntfscat rc=%d %s" % (p, rc, err.decode(errors="replace").strip()[:100]))
        elif sha(out) != want or len(out) != e["size"]:
            self.fail("ntfscat", "%s: size/hash mismatch (got %d bytes, manifest %d)" % (p, len(out), e["size"]))
        else:
            self.ok("ntfscat")
        ino = self.ifind(p)
        if ino is None:
            self.fail("tsk", "%s: ifind -n found nothing" % p)
        else:
            rc, out = self.icat(ino)
            if rc != 0 or sha(out) != want or len(out) != e["size"]:
                self.fail("tsk", "%s: icat %s mismatch (got %d bytes, manifest %d)" % (p, ino, len(out), e["size"]))
            else:
                self.ok("tsk")
        for s in e["streams"]:
            rc, out, err = self.ntfscat(p, s["name"])
            if rc != 0 or sha(out) != s["sha256"] or len(out) != s["size"]:
                self.fail("ntfscat", "%s:%s stream mismatch (rc=%d, %d bytes vs %d)" % (p, s["name"], rc, len(out), s["size"]))
            else:
                self.ok("ntfscat")
            cands = [i for i, d in fm.get(p + ":" + s["name"], []) if not d]
            if not cands:
                self.fail("tsk", "%s:%s not in fls output" % (p, s["name"]))
            else:
                rc, out = self.icat(cands[0])
                if rc != 0 or sha(out) != s["sha256"] or len(out) != s["size"]:
                    self.fail("tsk", "%s:%s icat %s mismatch" % (p, s["name"], cands[0]))
                else:
                    self.ok("tsk")
        return ino

    def check_features(self, e, ino):
        """The expect label must match what the image really contains (checked via TSK istat)."""
        ex = e["expect"]
        if ex in ("ok", "unsupported:attribute-list") or ino is None:
            return
        txt = self.istat(ino)
        need = {"unsupported:attribute-list": "$ATTRIBUTE_LIST", "unsupported:reparse": "$REPARSE_POINT",
                "unsupported:compression": "Compressed"}[ex]
        if need in txt:
            self.ok("features")
        else:
            self.fail("features", "%s: expect=%s but istat has no %s" % (e["path"], ex, need))

    def run(self):
        mf = self.mf
        ents = mf["entries"]
        fm = fls_map(self.img)
        # geometry (best effort, from fsstat)
        rc, out, _ = run(["fsstat", self.img])
        t = out.decode("utf-8", "replace")
        for key, want in (("Sector Size", mf["sectorSize"]), ("Cluster Size", mf["clusterSize"])):
            g = re.search(r"%s:\s*(\d+)" % key, t)
            if g:
                if int(g.group(1)) == want:
                    self.ok("features")
                else:
                    self.fail("features", "fsstat %s %s != manifest %s" % (key, g.group(1), want))
        g = re.search(r"Volume Name:\s*(.*)", t)
        if g and g.group(1).strip():
            if g.group(1).strip() == mf["volumeLabel"]:
                self.ok("features")
            else:
                self.fail("features", "fsstat label %r != manifest %r" % (g.group(1).strip(), mf["volumeLabel"]))

        self.check_header(mf)

        # content
        todo = [e for e in ents if e["type"] in ("file", "hardlink", "symlink") and e["sha256"]]
        inodes = {}

        def work(e):
            return e, self.check_content(e, fm)

        with cf.ThreadPoolExecutor(max_workers=4) as ex:
            for e, ino in ex.map(work, todo):
                inodes[e["path"]] = ino
        for e in ents:
            if e["expect"].startswith("unsupported:"):
                ino = inodes.get(e["path"]) or self.ifind(e["path"])
                self.check_features(e, ino)


        # label <-> oracle, both directions: AL on the entry's own record or any ancestor's
        inode = {"/": "5"}
        for p, v in fm.items():
            for i, d in v:
                if not d and ":" not in p.rsplit("/", 1)[-1]:
                    inode.setdefault(p, i.split("-")[0])

        def has_al(i):
            return i, "$ATTRIBUTE_LIST" in self.istat(i)

        liv = [e for e in ents if e["type"] != "deleted"]
        need = set()
        for e in liv:
            cur = e["path"]
            while True:
                if cur in inode:
                    need.add(inode[cur])
                if cur == "/":
                    break
                cur = parent(cur)
        with cf.ThreadPoolExecutor(max_workers=4) as ex:
            al = dict(ex.map(has_al, sorted(need)))
        for e in liv:
            cur, hit = e["path"], None
            while True:
                if al.get(inode.get(cur)):
                    hit = cur
                    break
                if cur == "/":
                    break
                cur = parent(cur)
            lab = e["expect"]
            if "attributeList" in e:  # explicit oracle field: must equal what TSK reports, both directions
                if bool(hit) == bool(e["attributeList"]):
                    self.ok("features")
                else:
                    self.fail("features", "%s: attributeList=%s but TSK says %s" % (e["path"], e["attributeList"], bool(hit)))
            elif lab == "unsupported:attribute-list":
                if hit:
                    self.ok("features")
                else:
                    self.fail("features", "%s labelled attribute-list but no $ATTRIBUTE_LIST on its path" % e["path"])
            elif lab == "ok":
                if not hit:
                    self.ok("features")
                else:
                    self.fail("features", "%s labelled ok but %s has an $ATTRIBUTE_LIST" % (e["path"], hit))

        # image-specific feature rules (does the image really exercise what it claims?)
        self.image_rules(ents, inodes)

        # hardlinks share one inode
        groups = {}
        for e in ents:
            if e["type"] == "hardlink" and inodes.get(e["path"]):
                groups.setdefault(e["linkTarget"], set()).add(inodes[e["path"]])
        for tgt, s in groups.items():
            if len(s) == 1:
                self.ok("features")
            else:
                self.fail("features", "hardlink group %s resolves to several inodes %s" % (tgt, sorted(s)))

        # directory listings via ntfsls
        live = [e for e in ents if e["type"] != "deleted"]
        children = {"/": set()}
        for e in live:
            if e["type"] == "dir":
                children.setdefault(e["path"], set())
        for e in live:
            children.setdefault(parent(e["path"]), set()).add(base(e["path"]))
        dead_names = {}
        for e in ents:
            if e["type"] == "deleted":
                dead_names.setdefault(parent(e["path"]), set()).add(base(e["path"]))

        def ls(d):
            rc, out, err = run(["ntfsls", "-f", "-q", "-p", d, self.img])
            return d, rc, out.decode("utf-8", "replace").splitlines(), err

        with cf.ThreadPoolExecutor(max_workers=4) as ex:
            for d, rc, names, err in ex.map(ls, sorted(children)):
                if rc != 0:
                    self.fail("ntfsls", "%s: ntfsls rc=%d %s" % (d, rc, err.decode(errors="replace").strip()[:80]))
                    continue
                got = set(n for n in names if n != "." and n != "..")
                want = children[d]
                if got == want:
                    self.ok("ntfsls")
                else:
                    self.fail("ntfsls", "%s: missing=%s extra=%s" % (d, sorted(want - got)[:5], sorted(got - want)[:5]))
        # a deleted name that is still shown by ntfsls is a hard failure (covered by `extra` above)

        # TSK tree: live paths in fls must equal live manifest paths (ignoring streams and system files)
        tsk_live = set(p for p, v in fm.items() if any(not d for _, d in v)
                       and ":" not in p.rsplit("/", 1)[-1] and not p.startswith("/$")
                       and not p.endswith("/."))
        want_live = set(e["path"] for e in live)
        if tsk_live == want_live:
            self.ok("fls")
        else:
            self.fail("fls", "tree differs: missing=%s extra=%s" % (sorted(want_live - tsk_live)[:5],
                                                                   sorted(tsk_live - want_live)[:5]))
        # informational: how many deleted entries TSK can still see
        seen = sum(1 for e in ents if e["type"] == "deleted" and any(d for _, d in fm.get(e["path"], [])))
        total = sum(1 for e in ents if e["type"] == "deleted")
        self.info = "(info: %d/%d deleted paths still resolvable in fls)" % (seen, total) if total else ""

    def volume_flags_tsk(self):
        """u16 flags of $VOLUME_INFORMATION read through TSK (istat 3 + icat 3-112-<id>)."""
        t = self.istat("3")
        g = re.search(r"Type: \$VOLUME_INFORMATION \(112-(\d+)\)", t)
        if not g:
            return None
        rc, out = self.icat("3-112-" + g.group(1))
        return struct.unpack_from("<H", out, 10)[0] if rc == 0 and len(out) >= 12 else None

    def check_header(self, mf):
        want_dirty = bool(mf.get("dirty", False))
        fl = self.volume_flags_tsk()
        rc, out, err = run(["ntfsinfo", "-m", "-f", self.img])
        g = re.search(r"Volume Flags:\s*0x([0-9a-fA-F]+)", out.decode("utf-8", "replace"))
        nf = int(g.group(1), 16) if g else None
        for who, f in (("TSK", fl), ("ntfsinfo", nf)):
            if f is None:
                self.fail("features", "dirty: %s could not read the volume flags" % who)
            elif bool(f & 1) == want_dirty:
                self.ok("features")
            else:
                self.fail("features", "dirty: manifest says %s but %s reads flags 0x%x" % (want_dirty, who, f))
        if "hibernated" in mf:
            rc, out, err = self.ntfscat("/hiberfil.sys")
            head = out[:4096]
            real = out[:4] == b"hibr"
            if real != mf["hibernated"]:
                self.fail("features", "hibernated: manifest %s but /hiberfil.sys starts with %r" % (mf["hibernated"], out[:4]))
            elif real and head[4:] != bytes(4092):
                self.fail("features", "hibernated: header page is not 'hibr' + zeros")
            elif not real and head != bytes(4096):
                self.fail("features", "hiberfil-woken: first 4 KiB are not all zero")
            else:
                self.ok("features")
        self.check_reparse()

    def check_reparse(self):
        ents = [e for e in self.mf["entries"] if e.get("reparse")]
        if not ents:
            return
        mnt = "/mnt/rp-" + self.name
        os.makedirs(mnt, exist_ok=True)
        rc, out, err = run(["ntfs-3g", "-o", "ro,force,streams_interface=xattr", self.img, mnt])
        if rc != 0:
            self.fail("features", "reparse: cannot mount read-only: " + err.decode(errors="replace")[:100])
            return
        try:
            for e in ents:
                r = e["reparse"]
                try:
                    raw = os.getxattr(mnt + e["path"], "system.ntfs_reparse_data", follow_symlinks=False)
                except OSError as ex:
                    self.fail("features", "%s: no reparse data (%s)" % (e["path"], ex))
                    continue
                tag, ln, _ = struct.unpack_from("<IHH", raw, 0)
                so, sl, po, pl = struct.unpack_from("<HHHH", raw, 8)
                if tag == 0xA000000C:
                    flags, base = struct.unpack_from("<I", raw, 16)[0], 20
                    kind = "symlink-dir" if "dir" in r["kind"] else "symlink-file"
                elif tag == 0xA0000003:
                    flags, base, kind = 0, 16, "junction"
                else:
                    self.fail("features", "%s: unexpected reparse tag 0x%x" % (e["path"], tag))
                    continue
                sub = raw[base + so:base + so + sl].decode("utf-16le")
                pr = raw[base + po:base + po + pl].decode("utf-16le")
                if (kind, sub, pr, flags) == (r["kind"], r["substituteName"], r["printName"], r["flags"]):
                    self.ok("features")
                else:
                    self.fail("features", "%s: reparse data %r != manifest %r" % (e["path"], (kind, sub, pr, flags), r))
        finally:
            run(["umount", mnt])

    def image_rules(self, ents, inodes):
        name = self.name

        def ino_of(p):
            return inodes.get(p) or self.ifind(p)

        if name == "sparse":
            for e in ents:
                if e["path"].startswith("/sp/") and "dense" not in e["path"]:
                    i = ino_of(e["path"])
                    if i and ", Sparse" in self.istat(i):
                        self.ok("features")
                    else:
                        self.fail("features", "%s: expected a sparse $DATA" % e["path"])
        if name == "fragmented":
            for e in ents:
                if e["type"] == "file":
                    i = ino_of(e["path"])
                    r = runs_of(self.istat(i)) if i else 0
                    if r >= 3:
                        self.ok("features")
                    else:
                        self.fail("features", "%s: only %d run(s), wanted a fragmented file" % (e["path"], r))
        if name == "attrlist":
            for p in ("/al/frag0.bin", "/al/frag1.bin", "/al/frag2.bin"):
                i = ino_of(p)
                r = runs_of(self.istat(i)) if i else 0
                if r >= 250:
                    self.ok("features")
                else:
                    self.fail("features", "%s: only %d runs" % (p, r))
            i = ino_of("/al/plain.txt")
            if i and "$ATTRIBUTE_LIST" not in self.istat(i):
                self.ok("features")
            else:
                self.fail("features", "/al/plain.txt should not have $ATTRIBUTE_LIST")
        if name == "manydirs":
            for p in ("/big", "/big/sub1"):
                i = self.ifind(p)
                if i and "$INDEX_ALLOCATION" in self.istat(i):
                    self.ok("features")
                else:
                    self.fail("features", "%s: expected $INDEX_ALLOCATION" % p)
        if name == "compressed":
            for e in ents:
                if e["path"].startswith("/plain/"):
                    i = ino_of(e["path"])
                    if i and "Compressed" not in self.istat(i):
                        self.ok("features")
                    else:
                        self.fail("features", "%s should not be compressed" % e["path"])
        if name == "ads":
            res = nonres = dirs = both = 0
            for e in ents:
                if not e["streams"]:
                    continue
                i = self.ifind(e["path"])
                t = self.istat(i) if i else ""
                if e["type"] == "dir":
                    dirs += 1
                elif e["sha256"]:
                    both += 1
                for s in e["streams"]:
                    line = next((l for l in t.splitlines() if l.startswith("Type: $DATA") and ("Name: %s " % s["name"]) in l), None)
                    if line is None:
                        self.fail("features", "%s:%s: no named $DATA in istat" % (e["path"], s["name"]))
                        continue
                    self.ok("features")
                    isres = "Non-Resident" not in line
                    res += isres and s["size"] <= 700
                    nonres += (not isres) and s["size"] > 700
                    if isres != (s["size"] <= 700) and s["size"] > 800:
                        self.fail("features", "%s:%s residency unexpected" % (e["path"], s["name"]))
            for what, cnt in (("resident named stream", res), ("non-resident named stream >700 B", nonres),
                              ("stream on a directory", dirs), ("file with default + named streams", both)):
                if cnt:
                    self.ok("features")
                else:
                    self.fail("features", "ads: manifest/image has no %s" % what)
        if name == "mini-attrlist":
            def rows(p):
                i = self.ifind(p)
                return al_rows(self.istat(i)) if i else [], (self.istat(i) if i else "")
            r, t = rows("/ds")
            m = re.search(r"Type: \$INDEX_ALLOCATION.*\n([0-9 ]*)\n", t)
            nums = [int(x) for x in (m.group(1).split() if m else [])]
            nruns = 1 + sum(1 for x, y in zip(nums, nums[1:]) if y != x + 1) if nums else 0
            checks = [("/ds has $ATTRIBUTE_LIST and >=2 index runs", bool(r) and nruns >= 2)]
            r, t = rows("/de")
            checks.append(("/de $INDEX_ALLOCATION extent with VCN>0 in an extension record", any(x[0] == 160 and x[2] > 0 for x in r)))
            hl = [e for e in ents if e["type"] == "hardlink"]
            r, t = rows(hl[0]["path"]) if hl else ([], "")
            checks.append((">=40 hard link paths", len(hl) >= 40))
            checks.append(("hard-link $FILE_NAME overflow into an extension record",
                           sum(1 for x in r if x[0] == 48) >= 40 and any(x[0] == 48 and x[1] != r[0][1] for x in r)))
            for f in ("/frag/f0.bin", "/frag/f1.bin", "/frag/f2.bin"):
                r, t = rows(f)
                checks.append((f + " $DATA extent with VCN>0", any(x[0] == 128 and x[2] > 0 for x in r)))
            checks.append(("all expect ok", all(e["expect"] == "ok" for e in ents)))
            for what, good in checks:
                if good:
                    self.ok("features")
                else:
                    self.fail("features", "mini-attrlist: " + what)


def main():
    mans = sorted(f for f in os.listdir(D) if f.endswith(".manifest.json"))
    paths = [os.path.join(D, m) for m in mans]
    fx = os.environ.get("CORPUS_FIXTURES", "/fixtures")
    if os.path.isdir(fx):
        paths += [os.path.join(fx, f) for f in sorted(os.listdir(fx)) if f.endswith(".manifest.json")]
    if ONLY:
        paths = [p for p in paths if os.path.basename(p)[:-len(".manifest.json")] in ONLY]
    mans = paths
    if not mans:
        sys.exit("no manifests in " + D)
    rows, bad_total = [], 0
    allbad = []
    for m in mans:
        c = Checker(m)
        c.info = ""
        try:
            c.run()
        except Exception as ex:
            c.fail("fls", "checker crashed: %r" % ex)
        rows.append(c)
        bad_total += sum(v[1] for v in c.n.values())
        allbad += ["%s: %s" % (c.name, b) for b in c.bad]
    hdr = ("image", "entries", "ntfscat", "tsk", "ntfsls", "fls-tree", "features", "result")
    print("%-12s %7s %12s %12s %10s %9s %10s  %s" % hdr)
    for c in rows:
        f = lambda k: "%d ok/%d bad" % tuple(c.n[k]) if c.n[k][1] else "%d ok" % c.n[k][0]
        bad = sum(v[1] for v in c.n.values())
        print("%-12s %7d %12s %12s %10s %9s %10s  %s %s" % (
            c.name, len(c.mf["entries"]), f("ntfscat"), f("tsk"), f("ntfsls"), f("fls"), f("features"),
            "PASS" if not bad else "MISMATCH(%d)" % bad, c.info))
    if allbad:
        print("\nMismatches (first 40):")
        for b in allbad[:40]:
            print("  " + b)
        print("\nFAIL: %d mismatches" % bad_total)
        sys.exit(1)
    print("\nPASS: all checks agree with the manifests")


if __name__ == "__main__":
    main()
