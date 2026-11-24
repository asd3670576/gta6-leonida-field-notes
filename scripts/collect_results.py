"""Collect every measurement we made into one machine-readable summary.

Reads only our own logs under H:\\leonida\\logs (no game data involved).
Writes results_summary.json + results_summary.md next to the logs.
"""
import ast
import json
import re
from pathlib import Path

LOGS = Path(r"H:\leonida\logs")
OUT_JSON = LOGS / "results_summary.json"
OUT_MD = LOGS / "results_summary.md"

res: dict = {}


def read(p: Path) -> str:
    """PowerShell '>' writes UTF-16LE; python '>' writes UTF-8. Sniff both."""
    try:
        data = p.read_bytes()
    except OSError:
        return ""
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", "replace")
    if b"\x00" in data[:400]:
        return data.decode("utf-16-le", "replace")
    return data.decode("utf-8", "replace")


def tail(p: Path, n: int = 400) -> list[str]:
    return read(p).splitlines()[-n:]


def one(pattern: str, text: str, group: int | None = None):
    m = re.search(pattern, text, re.S)
    if not m:
        return None
    return m.group(group) if group is not None else m.group(0)


# --- carve -------------------------------------------------------------------
t = read(LOGS / "carve.txt")
n, rej = one(r"(\d+) shaders carved, (\d+) candidates rejected", t, 1), one(
    r"(\d+) shaders carved, (\d+) candidates rejected", t, 2
)
stages = one(r"stages: (\{[^}]*\})", t, 1)
models = one(r"shader models: (\{[^}]*\})", t, 1)
res["carve"] = {
    "shaders": int(n) if n else None,
    "rejected": int(rej) if rej else None,
    "stages": ast.literal_eval(stages) if stages else None,
    "shader_models": ast.literal_eval(models) if models else None,
}

# --- fssm_unpack -------------------------------------------------------------
t = read(LOGS / "unpack.txt")
res["fssm_unpack"] = {
    "blobs": int(one(r"(\d+) FSSM blobs", t, 1) or 0) or None,
    "problems": one(r"problems: (\{[^}]*\})", t, 1),
    "sizes": one(r"size min .*", t),
}

# --- disasm ------------------------------------------------------------------
lines = tail(LOGS / "disasm_full.txt", 30)
res["disasm"] = {"last_lines": [l.strip()[:160] for l in lines if l.strip()][-4:]}

# --- translation shards ------------------------------------------------------
shard_rows = []
tier = {"A": 0, "B": 0, "C": 0}
tot_tr = tot_val = 0
for p in sorted(LOGS.glob("shards/shard*.log")):
    txt = read(p)
    m = re.search(r"(\d+) shaders: (\d+) translated, (\d+) pass spirv-val", txt)
    tm = re.search(r"tier A: (\d+), tier B: (\d+), tier C: (\d+)", txt)
    if m:
        tot_tr += int(m.group(2))
        tot_val += int(m.group(3))
        shard_rows.append(
            {"shard": p.stem, "total": int(m.group(1)), "translated": int(m.group(2)), "spirv_val_ok": int(m.group(3))}
        )
    if tm:
        tier["A"] += int(tm.group(1))
        tier["B"] += int(tm.group(2))
        tier["C"] += int(tm.group(3))
res["translate"] = {
    "shards": len(shard_rows),
    "translated": tot_tr,
    "spirv_val_ok": tot_val,
    "wave64_graphics_tiers": tier,
    "per_shard": shard_rows,
}
t = read(LOGS / "merge.txt")
res["translate"]["merged_entries"] = int(one(r"merged (\d+) entries", t, 1) or 0) or None

# --- pipeline check (slice + full) ------------------------------------------
def parse_pipeline(path: Path) -> dict:
    txt = read(path)
    out: dict = {}
    out["shaders_in_index"] = int(one(r"(\d+) shaders in index", txt, 1) or 0) or None
    per = {}
    for stage in ("cs", "ms", "ps", "vs", "gs"):
        m = re.search(
            rf"^{stage}: (\d+) modules ok, (\d+) failed\s*\n"
            rf"{stage} pipelines: (\d+) ok, (\d+) failed, (\d+) skipped\s*\n"
            rf"  {stage} wave32: (\d+) ok, (\d+) failed; wave64: (\d+) ok, (\d+) failed(?: \((\d+) without required subgroup size\))?\s*\n"
            rf"  {stage} compile time: ([\d.]+)s total, ([\d.]+)s mean, slowest (\S+) \(([\d.]+)s\)",
            txt,
            re.M,
        )
        if m:
            per[stage] = {
                "modules_ok": int(m.group(1)),
                "modules_failed": int(m.group(2)),
                "pipelines_ok": int(m.group(3)),
                "pipelines_failed": int(m.group(4)),
                "pipelines_skipped": int(m.group(5)),
                "wave32_ok": int(m.group(6)),
                "wave32_failed": int(m.group(7)),
                "wave64_ok": int(m.group(8)),
                "wave64_failed": int(m.group(9)),
                "wave64_no_required_subgroup": int(m.group(10) or 0),
                "compile_total_s": float(m.group(11)),
                "compile_mean_s": float(m.group(12)),
                "slowest": m.group(13),
                "slowest_s": float(m.group(14)),
            }
    out["per_stage"] = per
    out["wall_time"] = one(r"wall time: .*", txt)
    out["cache_line"] = one(r"pipeline cache: .*", txt)
    prog = re.findall(r"pipelines (\d+) \((\d+)s elapsed\)", txt)
    out["progress_lines"] = [{"pipelines": int(a), "elapsed_s": int(b)} for a, b in prog][-6:]
    out["still_compiling_warnings"] = len(re.findall(r"still compiling", txt))
    out["cache_save_failures"] = len(re.findall(r"periodic pipeline cache save .* failed", txt))
    out["cache_save_error"] = one(r"periodic pipeline cache save .*?: (\S+)", txt, 1)
    out["slow_lines"] = [l.strip() for l in txt.splitlines() if l.strip().startswith("SLOW")][:12]
    return out


res["pipeline_slice"] = parse_pipeline(LOGS / "pipeline_slice.txt")
res["pipeline_full"] = parse_pipeline(LOGS / "pipeline_full.txt")
stats = LOGS / "pipeline_stats_full.txt"
if stats.exists():
    # count distinct modules already recorded, opened shareably
    import io

    names = set()
    with stats.open("rb") as f:
        data = f.read()
    for line in data.decode("utf-8", "replace").splitlines():
        m = re.match(r"^(.*?),(vs|ps|cs|ms|gs),", line)
        if m:
            names.add(m.group(1))
    res["pipeline_full"]["modules_in_stats"] = len(names)
    res["pipeline_full"]["stats_bytes"] = len(data)

# --- package completeness ----------------------------------------------------
t = read(LOGS / "missing_files_fix.txt")
res["package"] = {
    "manifest_entries": int(one(r"manifest entries = (\d+)", t, 1) or 0) or None,
    "present_ok_size": int(one(r"present_ok_size=(\d+)", t, 1) or 0) or None,
    "size_mismatch": int(one(r"size_mismatch=(\d+)", t, 1) or 0) or None,
    "absent": int(one(r"absent=(\d+)", t, 1) or 0) or None,
    "verified": int(one(r"verified=(\d+)", t, 1) or 0) or None,
    "verified_bytes": int(one(r"verified bytes = (\d+)", t, 1) or 0) or None,
    "installed": int(one(r"installed = (\d+)", t, 1) or 0) or None,
}
t = read(LOGS / "make_check_after_fix.txt")
res["package"]["check_output"] = [l.strip() for l in t.splitlines() if l.strip()]

OUT_JSON.write_text(json.dumps(res, indent=2, ensure_ascii=False), encoding="utf-8")

# --- markdown rendering ------------------------------------------------------
md = []
md.append("# Leonida (GTA VI Xbox Series recompiler) - measurements from one PC\n")
md.append(
    "Machine: Windows 10 Pro for Workstations 19045 x64, AMD Ryzen 9 5950X (16C/32T), 64 GB RAM, "
    "NVIDIA GeForce RTX 3080 **20 GB**, driver 610.88, Vulkan 1.4.341, subgroup 32-32. "
    "Python 3.12.14, LLVM 23.1.6 (`llvm-mc` gfx1013), SPIRV-Tools 2026.4.\n"
)
c = res["carve"]
md.append("## shader_carve (shaders.rpf -> DXBC)")
md.append(
    f"- {c['shaders']} shaders carved, {c['rejected']} candidate rejected; "
    f"stages {c['stages']}; shader models {c['shader_models']}\n"
)
u = res["fssm_unpack"]
md.append("## fssm_unpack")
md.append(f"- {u['blobs']} FSSM blobs, problems {u['problems']}")
md.append(f"- {u['sizes']}\n")
tr = res["translate"]
md.append("## rdna2spirv (DXBC -> SPIR-V, 16 shards, --wave64-emulate)")
md.append(
    f"- {tr['translated']} translated, {tr['spirv_val_ok']} pass spirv-val, merged {tr['merged_entries']} entries"
)
md.append(
    f"- wave64 VS/PS/GS on 32-wide subgroups: tier A {tr['wave64_graphics_tiers']['A']}, "
    f"tier B {tr['wave64_graphics_tiers']['B']}, tier C {tr['wave64_graphics_tiers']['C']}\n"
)
for key, label in (("pipeline_slice", "vk_pipeline_check slice (1500 modules, --jobs 8)"), ("pipeline_full", "vk_pipeline_check full corpus")):
    p = res[key]
    md.append(f"## {label}")
    if p.get("shaders_in_index"):
        md.append(f"- index: {p['shaders_in_index']} shaders")
    for stage, d in sorted(p.get("per_stage", {}).items()):
        md.append(
            f"- {stage}: {d['modules_ok']} modules ok / {d['modules_failed']} failed; "
            f"pipelines {d['pipelines_ok']} ok / {d['pipelines_failed']} failed / {d['pipelines_skipped']} skipped; "
            f"wave32 {d['wave32_ok']} ok, wave64 {d['wave64_ok']} ok ({d['wave64_no_required_subgroup']} without required subgroup size); "
            f"mean {d['compile_mean_s']}s, slowest {d['slowest']} {d['slowest_s']}s"
        )
    if p.get("wall_time"):
        md.append(f"- {p['wall_time']}")
    if p.get("cache_line"):
        md.append(f"- {p['cache_line']}")
    if p.get("modules_in_stats"):
        md.append(f"- modules recorded in stats file: {p['modules_in_stats']}")
    if p.get("progress_lines"):
        last = p["progress_lines"][-1]
        md.append(f"- last progress line: {last['pipelines']} pipelines, {last['elapsed_s']}s elapsed")
    if p.get("cache_save_failures"):
        md.append(
            f"- periodic pipeline cache save failed {p['cache_save_failures']}x: {p['cache_save_error']}"
        )
    if p.get("still_compiling_warnings"):
        md.append(f"- 'still compiling' warnings: {p['still_compiling_warnings']}")
    md.append("")
pk = res["package"]
md.append("## package completeness")
md.append(
    f"- manifest {pk['manifest_entries']} entries: {pk['present_ok_size']} present with matching size, "
    f"{pk['size_mismatch']} size mismatches, {pk['absent']} absent"
)
md.append(
    f"- restored {pk['verified']} of the absent entries from the package's own torrent "
    f"({pk['verified_bytes']} bytes), all matching manifest size + SHA-256, then re-verified in place"
)
for line in pk.get("check_output", []):
    md.append(f"- `make_game.py --check`: {line}")
md.append("")
OUT_MD.write_text("\n".join(md), encoding="utf-8")
print(json.dumps(res, indent=2, ensure_ascii=False)[:4000])
print(f"\nwrote {OUT_JSON}\nwrote {OUT_MD}")
