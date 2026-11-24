"""Build an aria2 input file that fetches ONLY the package files missing on disk.

Reads the CYBERLEEK .torrent, compares its file list with what is on disk, and
emits aria2 per-download options (select-file=<1-based indices>, dir=<staging>).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from pkg_diff import bdecode, on_disk, TORRENT, PKG  # noqa: E402

STAGING = Path(r"H:\leonida\pkg-missing")
INPUT = STAGING / "aria2_input.txt"
LISTING = STAGING / "torrent_files.txt"
TORRENT_COPY = Path(r"H:\leonida\game.torrent")


def main():
    STAGING.mkdir(parents=True, exist_ok=True)
    TORRENT_COPY.parent.mkdir(parents=True, exist_ok=True)
    if not TORRENT_COPY.exists():
        TORRENT_COPY.write_bytes(TORRENT.read_bytes())
    meta, _ = bdecode(TORRENT_COPY.read_bytes())
    info = meta[b"info"]
    files = info[b"files"]
    disk = on_disk()

    rows, want_idx, missing = [], [], []
    for i, f in enumerate(files, start=1):
        rel = "/".join(x.decode("utf-8", "replace") for x in f[b"path"])
        size = int(f[b"length"])
        present = rel.lower() in disk
        rows.append(f"{i:>4}  {'OK ' if present else 'MISS'}  {size:>14,}  {rel}")
        if not present:
            want_idx.append(str(i))
            missing.append((rel, size))

    LISTING.write_text("\n".join(rows) + "\n", encoding="utf-8")

    trackers = []
    for group in meta.get(b"announce-list", []):
        for t in group:
            trackers.append(t.decode("utf-8", "replace"))
    if not trackers and b"announce" in meta:
        trackers.append(meta[b"announce"].decode("utf-8", "replace"))
    trackers = list(dict.fromkeys(trackers))

    lines = [str(TORRENT_COPY),
             f"  dir={STAGING.as_posix()}",
             f"  select-file={','.join(want_idx)}",
             "  file-allocation=none",
             "  seed-time=0",
             "  continue=true",
             "  auto-file-renaming=false",
             "  allow-overwrite=true",
             ""]
    INPUT.write_text("\n".join(lines), encoding="utf-8")

    print(f"torrent entries={len(files)}  on-disk={len(disk)}  missing={len(missing)}")
    print(f"missing total = {sum(s for _, s in missing):,} bytes "
          f"({sum(s for _, s in missing)/2**20:.1f} MiB)")
    print(f"trackers: {trackers}")
    print(f"input file: {INPUT}")
    print("\n".join(f"  MISS {s:>12,}  {r}" for r, s in missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
