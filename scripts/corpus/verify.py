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
            if lab == "unsupported:attribute-list":
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
            for e in ents:
                if e["streams"]:
                    i = self.ifind(e["path"])
                    if i and sum(1 for l in self.istat(i).splitlines() if l.startswith("Type: $DATA") and "Name: N/A" not in l) >= 1 \
                            or e["type"] == "dir":
                        self.ok("features")
                    else:
                        self.fail("features", "%s: no named $DATA in istat" % e["path"])


def main():
    mans = sorted(f for f in os.listdir(D) if f.endswith(".manifest.json"))
    paths = [os.path.join(D, m) for m in mans]
    fx = os.environ.get("CORPUS_FIXTURES", "/fixtures")
    if os.path.exists(fx + "/mini.manifest.json"):
        paths.append(fx + "/mini.manifest.json")
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
