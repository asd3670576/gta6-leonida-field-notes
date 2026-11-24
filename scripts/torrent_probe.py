"""Print the torrent's info-hash / magnet, and ask public trackers for peer counts."""
import hashlib
import urllib.parse
import urllib.request

from pathlib import Path
import sys

sys.path.insert(0, r"H:\DSH任务\leonida-check")
from pkg_diff import bdecode  # noqa: E402

TOR = Path(r"H:\leonida\game.torrent")


def bencode(obj):
    if isinstance(obj, bytes):
        return f"{len(obj)}:".encode() + obj
    if isinstance(obj, int):
        return f"i{obj}e".encode()
    if isinstance(obj, list):
        return b"l" + b"".join(bencode(x) for x in obj) + b"e"
    if isinstance(obj, dict):
        out = b"d"
        for k in sorted(obj, key=lambda x: x.lower() if isinstance(x, bytes) else x):
            out += bencode(k) + bencode(obj[k])
        return out + b"e"
    raise TypeError(type(obj))


raw = TOR.read_bytes()
meta, _ = bdecode(raw)
info_hash = hashlib.sha1(bencode(meta[b"info"])).hexdigest()
ih_raw = bytes.fromhex(info_hash)
print(f"info_hash(hex) = {info_hash}")
print(f"magnet         = magnet:?xt=urn:btih:{info_hash}")
print(f"piece size     = {int.from_bytes(meta[b'info'][b'piece length'], 'big') if isinstance(meta[b'info'][b'piece length'], bytes) else meta[b'info'][b'piece length']}")
n_pieces = len(meta[b"info"][b"pieces"]) // 20
print(f"pieces         = {n_pieces}")

trackers = [
    "http://open.tracker.cl:1337",
    "http://tracker.opentrackr.org:1337",
    "http://tracker.torrent.eu.org:451",
    "http://tracker.openbittorrent.com:6969",
    "http://tracker.gbitt.info:80",
]
q = "info_hash=" + urllib.parse.quote_from_bytes(ih_raw)
print("\n== scrape (complete=seeders, incomplete=leechers, downloaded) ==")
for t in trackers:
    url = f"{t}/scrape?{q}"
    try:
        with urllib.request.urlopen(url, timeout=12) as fh:
            body = fh.read().decode("utf-8", "replace")
        print(f"  {t}\n    {body.strip()[:400]}")
    except Exception as exc:  # noqa: BLE001
        print(f"  {t}\n    ERR {type(exc).__name__}: {exc}")
