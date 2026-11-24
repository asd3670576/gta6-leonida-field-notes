"""Compare the package against the Leonida repo manifest, verify the BT-staged
copies by size + SHA-256, and (with --copy) install the verified ones.

Nothing here prints game *contents*; only names, byte counts and hashes.
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

MANIFEST = Path(r"H:\leonida\Leonida\game\xbox-1.0.2.1.json")
PKG = Path(r"H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK")
STAGE = Path(r"H:\leonida\pkg-missing\GTA6.Xbox.v1.0.2.1-CYBERLEEK")
LOG = Path(r"H:\leonida\logs\missing_files_fix.txt")

DO_COPY = "--copy" in sys.argv

man = json.loads(MANIFEST.read_text(encoding="utf-8"))
files = man["files"]


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


lines = []


def say(msg: str) -> None:
    print(msg, flush=True)
    lines.append(msg)


say(f"manifest entries = {len(files)}  (version {man.get('version')})")

present = absent = mismatch = 0
missing = []
for name, e in sorted(files.items()):
    exp_size = int(e["size"])
    exp_sha = str(e["sha256"]).lower()
    p = PKG / name
    if not p.exists():
        absent += 1
        missing.append((name, exp_size, exp_sha))
        continue
    size = p.stat().st_size
    if size != exp_size:
        mismatch += 1
        say(f"SIZE-MISMATCH in package: {name} disk={size} manifest={exp_size}")
    else:
        present += 1

say(f"package: present_ok_size={present} size_mismatch={mismatch} absent={absent}")

verified = []
not_staged = []
bad = []
for name, exp_size, exp_sha in missing:
    sp = STAGE / name
    if not sp.exists():
        not_staged.append(name)
        continue
    size = sp.stat().st_size
    if size != exp_size:
        bad.append(f"{name}: staged size {size} != manifest {exp_size}")
        continue
    got = sha256(sp)
    if got != exp_sha:
        bad.append(f"{name}: staged sha {got} != manifest {exp_sha}")
        continue
    verified.append((name, size, got, sp))

say(f"staged candidates={len(missing) - len(not_staged)} verified={len(verified)} hash_bad={len(bad)} not_staged={len(not_staged)}")
for b in bad:
    say("BAD " + b)
for n in not_staged:
    say("NOT-STAGED " + n)

total_bytes = sum(v[1] for v in verified)
say(f"verified bytes = {total_bytes}")

if DO_COPY:
    installed = 0
    for name, size, got, sp in verified:
        dst = PKG / name
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            say(f"SKIP (already there) {name}")
            continue
        shutil.copy2(sp, dst)
        after = dst.stat().st_size
        ok = after == size and sha256(dst) == got
        say(f"INSTALLED {name} size={after} sha256={got} verify={'ok' if ok else 'FAIL'}")
        if ok:
            installed += 1
    say(f"installed = {installed}")

LOG.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"log -> {LOG}")
