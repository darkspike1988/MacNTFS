#!/usr/bin/env python3
"""Verify Swift writes with installed Tuxera tools, using a disposable image only."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unicodedata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=Path(__file__).resolve().parents[1] / ".build/debug/macntfs")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    cli = args.cli.resolve()
    tools = Path("/Library/Filesystems/tuxera_ntfs.fs/Contents/Resources/Support/10.9")
    records = []

    def run(argv):
        result = subprocess.run(list(map(str, argv)), capture_output=True, timeout=30)
        records.append({"command": list(map(str, argv)), "exit": result.returncode,
                        "stdout": result.stdout.decode("utf-8", errors="replace"),
                        "stderr": result.stderr.decode("utf-8", errors="replace")})
        if result.returncode:
            raise RuntimeError(json.dumps(records[-1], ensure_ascii=False, indent=2))
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="macntfs-tuxera-interop-") as directory:
        root = Path(directory)
        image = root / "offline.img"
        with image.open("wb") as handle:
            handle.truncate(64 * 1024 * 1024)
        run([tools / "mkntfs", "-F", "-Q", "-L", "SWIFT_INTEROP", image])
        expected = {}
        for index in range(134):
            name = f"file-{index:03}.txt" if index < 130 else ["Äpfel.txt", "larger.bin", "empty.txt", "Résumé.txt"][index - 130]
            payload = (f"Swift payload {index}\n".encode() if index < 130 else
                       ["Unicode payload\n".encode(), bytes(range(256)) * 80, b"", b"resume payload"][index - 130])
            source = root / "source"
            source.write_bytes(payload)
            run([cli, "write", image, source, name])
            expected[name] = payload
        listed = run([tools / "ntfsls", "-i", image]).decode()
        # Tuxera's macOS display returns canonically decomposed UTF-8 names.
        observed = {unicodedata.normalize("NFC", line.split(maxsplit=1)[1])
                    for line in listed.splitlines() if line.strip()}
        assert observed == set(expected), (observed ^ set(expected))
        for name, payload in expected.items():
            assert run([cli, "cat", image, "/" + name]) == payload, name
        before = hashlib.sha256(image.read_bytes()).hexdigest()
        run([tools / "ntfsck", "-s", "-P", "-t", "15", image])
        assert hashlib.sha256(image.read_bytes()).hexdigest() == before, "Simulated checker changed image"
        summary = {"files": len(expected), "tuxera_listing": "passed", "swift_readback": "passed",
                   "tuxera_full_simulated_check": "passed", "checker_changed_image": False,
                   "image_sha256": before, "cli_sha256": hashlib.sha256(cli.read_bytes()).hexdigest(),
                   "tool_sha256": {name: hashlib.sha256((tools / name).read_bytes()).hexdigest()
                                   for name in ["mkntfs", "ntfsls", "ntfsck"]}, "commands": records}
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        print(json.dumps({key: value for key, value in summary.items() if key != "commands"}, indent=2))


if __name__ == "__main__":
    main()
