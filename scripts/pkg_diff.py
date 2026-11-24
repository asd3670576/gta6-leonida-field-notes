"""Compare the CYBERLEEK package on disk against (a) its own .torrent file list
and (b) Leonida's game/xbox-1.0.2.1.json manifest. Read-only; prints a report."""
import json
import sys
import urllib.request
from pathlib import Path

PKG = Path(r"H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK")
TORRENT = PKG / "465D6A0EAC381E68CA77115F44F19F0C968B9590.torrent"
MANIFEST_URL = "https://raw.githubusercontent.com/ItsNotRexed/Leonida/main/game/xbox-1.0.2.1.json"


def bdecode(data, i=0):
    c = data[i:i + 1]
    if c == b"d":
        out = {}
        i += 1
        while data[i:i + 1] != b"e":
            k, i = bdecode(data, i)
            v, i = bdecode(data, i)
            out[k] = v
        return out, i + 1
    if c == b"l":
        out = []
        i += 1
        while data[i:i + 1] != b"e":
            v, i = bdecode(data, i)
            out.append(v)
        return out, i + 1
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1:j]), j + 1
    if c.isdigit():
        j = data.index(b":", i)
        n = int(data[i:j])
        return data[j + 1:j + 1 + n], j + 1 + n
    raise ValueError(f"bad token at {i}: {c!r}")


def on_disk():
    files = {}
    for p in PKG.rglob("*"):
        if p.is_file():
            files[p.relative_to(PKG).as_posix().lower()] = (p.relative_to(PKG).as_posix(), p.stat().st_size)
    return files


def main():
    disk = on_disk()
    print(f"== on disk: {len(disk)} files, {sum(s for _, s in disk.values())/2**30:.2f} GiB")

    # --- torrent side ---
    torrent_files = {}
    if TORRENT.exists():
        meta, _ = bdecode(TORRENT.read_bytes())
        info = meta[b"info"]
        total = sum(s for _, s in disk.values())
        if b"files" in info:
            for f in info[b"files"]:
                rel = "/".join(x.decode("utf-8", "replace") for x in f[b"path"])
                torrent_files[rel.lower()] = (rel, int(f[b"length"]))
            top = info.get(b"name", b"").decode("utf-8", "replace")
            print(f"== torrent: multi-file, name={top!r}, entries={len(torrent_files)}, "
                  f"torrent_total={sum(s for _, s in torrent_files.values())/2**30:.2f} GiB, "
                  f"disk_total={total/2**30:.2f} GiB")
        else:
            print("== torrent: single-file:", info.get(b"name"), info.get(b"length"))

        print("\n== IN TORRENT, NOT ON DISK (还没下到的文件) ==")
        missing = [(r, s) for k, (r, s) in torrent_files.items() if k not in disk]
        for r, s in sorted(missing, key=lambda x: -x[1]):
            print(f"  MISSING {s:>16,}  {r}")
        print(f"  -> {len(missing)} missing, {sum(s for _, s in missing)/2**30:.2f} GiB")
        print("\n== ON DISK, NOT IN TORRENT ==")
        extra = [(r, s) for k, (r, s) in disk.items() if torrent_files and k not in torrent_files]
        for r, s in sorted(extra, key=lambda x: -x[1]):
            print(f"  EXTRA   {s:>16,}  {r}")
        print("\n== SIZE MISMATCH vs torrent ==")
        for k, (r, s) in disk.items():
            if k in torrent_files and torrent_files[k][1] != s:
                print(f"  DIFF {r}: disk {s:,} vs torrent {torrent_files[k][1]:,}")
    else:
        print("== torrent file not found")

    # --- Leonida manifest side ---
    try:
        with urllib.request.urlopen(MANIFEST_URL, timeout=30) as fh:
            man = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        print(f"\n== manifest fetch failed: {exc}")
        return

    entries = man.get("files") or man.get("entries") or man
    if isinstance(entries, dict):
        items = [(k, v) for k, v in entries.items()]
    else:
        items = [(e.get("path") or e.get("name"), e) for e in entries]

    def size_of(v):
        if isinstance(v, dict):
            for key in ("size", "bytes", "length"):
                if key in v:
                    return int(v[key])
        elif isinstance(v, int):
            return v
        return None

    print(f"\n== Leonida manifest: {len(items)} entries; top-level keys={list(man)[:8] if isinstance(man, dict) else 'n/a'}")
    miss, wrong, ok = [], [], 0
    man_keys = set()
    for path, v in items:
        if not path:
            continue
        key = str(path).lower()
        man_keys.add(key)
        want = size_of(v)
        if key not in disk:
            miss.append((str(path), want))
        elif want is not None and disk[key][1] != want:
            wrong.append((str(path), disk[key][1], want))
        else:
            ok += 1
    print(f"  OK={ok}  MISSING={len(miss)}  SIZE-MISMATCH={len(wrong)}")
    print("\n== IN MANIFEST, NOT ON DISK ==")
    for p, s in sorted(miss, key=lambda x: -(x[1] or 0)):
        print(f"  MISSING {(s if s is not None else -1):>16,}  {p}")
    print("\n== SIZE MISMATCH vs manifest ==")
    for p, got, want in wrong:
        print(f"  DIFF {p}: disk {got:,} vs manifest {want:,}")
    print("\n== ON DISK, NOT IN MANIFEST ==")
    for k, (r, s) in sorted(disk.items()):
        if k not in man_keys:
            print(f"  EXTRA   {s:>16,}  {r}")


if __name__ == "__main__":
    sys.exit(main())
