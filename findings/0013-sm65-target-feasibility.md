# 0013 - Can XCL target Shader Model 6.5, so it runs on this Windows 10?

**Date:** 2026-11-24. **Repo:** ivall/xcl main @ 64b3f35. **Host:** Windows 10 19045.3324, 
RTX 3080 20 GB, driver 610.88, DXC 1.9.2609.5. Measured, not inferred: XCLs own HLSL output
compiled by standalone DXC at three targets.

# 0013 — Can XCL's RDNA2→HLSL→DXIL recompiler target Shader Model 6.5?

Measured on `H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK\shaders.rpf` (RPF9, 392.6 MB, 26 503 records,
26 698 FSSM programs) with standalone `H:\leonida\dxc\bin\x64\dxc.exe` (dxcompiler 1.9.2609.5); no
GPU, no `xcl run`, no Agility SDK. All artifacts under `H:\leonida\sm65_probe\`.

## 1. Where the target is chosen, and where the gate is

| what | file:line |
|---|---|
| SM 6.6 hard gate (`D3D12_FEATURE_DATA_SHADER_MODEL` → `format_no_sm66_message`) | `crates/xcl/src/gpu/recomp/runner.rs:101-105` |
| second device requirement (WaveOps + Int64ShaderOps) | `runner.rs:109-111` |
| ABI comment naming the reason: heaps "directly indexed (SM 6.6 `ResourceDescriptorHeap`)" | `runner.rs:125-129` |
| preflight probe of 6_6/6_5/6_0 and the Error-level "shaders cannot run" | `crates/xcl/src/preflight.rs:133`, `:68` |
| DXC target strings: FSPX CS / VS / PS / CS | `pso.rs:460`, `pso.rs:476-478` |
| two-pass compute + mesh pass-through (`cs_6_6`, `ms_6_6`) | `pso.rs:512`, `pso.rs:514` |
| rect-list GS (`gs_6_6`) | `pso.rs:592` |
| kernel CS | `runner.rs:597`, `runner.rs:608` (test-only: `mesh_dispatch.rs:269,309`) |
| the actual dxc argv: `-E main -T <profile> -HV 2021`, `-O1` >1 MB, `-O0` >8 MB | `dxc.rs:468-482` |
| `[WaveSize(n)]` emitted at 5 entry points | `emit.rs:4139, 4238, 4291, 4326, 4388` |
| `ResourceDescriptorHeap[NonUniformResourceIndex(…)]` / `SamplerDescriptorHeap[…]` | `emit.rs:2169, 2273, 2296, 2324, 2353, 2364, 2387`, `:1553` |
| `globallycoherent` mem windows, root UAVs `io`/`res`/`mem` | `emit.rs:4081-4090` |
| 64-bit atomics (`InterlockedAdd64`, `InterlockedCompareExchange64`) | `emit.rs:4855-4901, 4951-4958` |

**No env var or config key could lower the target before this probe.** Every `XCL_*` was scanned
(`grep 'env::var("XCL_'`): the closest are `XCL_SPLIT_WAVE64` (`pso.rs:540`), `XCL_RECOMP_WINDOWS`,
`XCL_DXC_DIR`, `XCL_DXC_THREADS`; `XCL_TIME_PROFILE` only sets a profile inside a timing test.

## 2. Getting real HLSL out (no device needed)

`xcl shaders <rpf> --help` prints no usage (exit 1, runs the default analysis); flags are in
`crates/xcl/src/main.rs:32-40`. `xcl rpf --extract` writes raw records, not HLSL; `xcl shaders`
writes HLSL with no device and no pipeline through `--recomp` + `XCL_DUMP_HLSL=<dir>`
(`shaders.rs:1274-1285`): `XCL_DUMP_EVERY=100 … xcl.exe shaders shaders.rpf --recomp` took 23 s,
exit 0, and reported `programs 26698, fully translated 26698 (100.0%), translation errors 0,
HLSL: 9236.8 MB`; by mode CS 2689, GS 390, MS 9282, PS 12101, VS 2236 — all 100 % complete.
A second, disjoint sample (`XCL_DUMP_EVERY=101`, 230 files) → **483 programs, 81.8 + 69.1 MB of
real translated HLSL**, manifest `sm65_probe\src\manifest.csv` (`name,stage,record,bytes,
xcl_profile`; `name`/`record` = XCL's `name_hash` of the program name). The dump's `MS`/`GS` files
are the **compute** passes (`cs_6_6`); the `ms_6_6` pass-through is only built at `pso.rs:514`, so
it was probed with a hand-written equivalent instead.

## 3. dxc command lines (XCL's own argv, only `-T` varies)

```
dxc.exe -E main -T {cs,vs,ps}_6_6 -HV 2021 f.hlsl -Fo o.dxil      # and _6_5, with and without -HV
dxc.exe -E main -T ms_6_5 | ms_6_6 -HV 2021 mesh_pass_through.hlsl -Fo o.dxil
```
`-O1` for the 17 files > 1 MB, `-O0` for > 8 MB (none), exactly as `dxc.rs:478-483`. Per-file exit
codes + first error lines: `results.csv` (759 rows), `results_b.csv` (690), `results_65rewrite.csv`
(253); dxc's full text per run in `raw\`.

## 4. Results

| stage | profile | n | ok@6.6 | ok@6.5 | ok@6.5 after rewrite |
|---|---|---|---|---|---|
| CS | cs_6_x | 49 | 49 | 0 | 49 |
| VS | vs_6_x | 39 | 39 | 32 | 39 |
| PS | ps_6_x | 195 | 195 | 30 | 195 |
| MS (NGG compute pass) | cs_6_x | 188 | 188 | 0 | 188 |
| GS (two-pass compute) | cs_6_x | 12 | 12 | 0 | 12 |
| **all** | | **483** | **483 (100 %)** | **62 (12.8 %)** | **483 (100 %)** |

`-HV 2021` is not a factor: dropping it changed nothing (33/253 and 29/230 identical).
The mesh pass-through compiles at `ms_6_5` (exit 0, with and without `-HV 2021`).

## 5. Construct histogram (483 programs; "blocked" = DXC refuses it at 6.5)

| construct | uses it | fails@6.5 | fails *only* from it |
|---|---|---|---|
| `ResourceDescriptorHeap[` | 302 (62.5 %) | 302 | 153 |
| `SamplerDescriptorHeap[` | 211 (43.7 %) | 211 | 0 (never without RDH) |
| `[WaveSize(n)]` | 249 (51.6 %) | 249 | 119 |
| `globallycoherent` | 49 (all CS) | 0 — compiles at cs_6_5 | 0 |
| `Interlocked*64` atomics | 0 | would block (snippet: "64-bit atomic operations … Shader Model 6.6+") | – |
| `uint64_t`/`int64_t` arithmetic | 483 | 0 | 0 |
| `NonUniformResourceIndex` | 302 | 0 alone (compiles at 6.5 on a declared array) | 0 |
| wave intrinsics + `select()` | 483 | 0 | 0 |
| mesh/NGG builtins (`SetMeshOutputCounts`, `out vertices/indices`) | probed | 0 at ms_6_5 | 0 |
| `rayquery` | 0 | – | – |
| `register(u0/u1/u2…)` root-UAV ABI | 483 | 0 | 0 |

Failure combos (A+B, 421 failing files): `RDH+SamplerHeap` 154, `WaveSize` only 119,
`RDH+WaveSize` 73, `RDH+SamplerHeap+WaveSize` 57, `RDH` only 18.

## 6. Representative errors (verbatim, shortened)

```
013d58d41c1fc8f4_MS  cs_6_5  error: attribute wavesize requires shader model 6.6 or greater
026f118d6d34ce20_PS  ps_6_5  error: use of undeclared identifier 'ResourceDescriptorHeap'
06fefeb7d579a2fc_PS  ps_6_5  error: use of undeclared identifier 'SamplerDescriptorHeap'
snippets/int64_atomics.hlsl cs_6_5  error: opcode '64-bit atomic operations' should only be used
                                       in 'Shader Model 6.6+'.
snippets/rdh_texture.hlsl   lib_6_5 error: use of undeclared identifier 'ResourceDescriptorHeap'
                                       (lib_6_6: exit 0; ps_6_5: same undeclared error)
```

## 7. Verdict

* **12.8 % (62/483)** of the sampled programs compile at SM 6.5 as XCL emits today; 0 % of CS/MS/GS.
* Two causes, one of them hard. DXC declares `ResourceDescriptorHeap`/`SamplerDescriptorHeap` at 6.6
  only, and **62.5 % (302/483)** of the programs index it — that *is* the XCL shader ABI
  (`runner.rs:125-129`, `pso::abi_root_signature`). `[WaveSize]` (51.6 %) is fatal on its own for 119
  programs: dropping it alone reaches **181/483 = 37.5 %**, which is exactly 483−302 — everything
  that touches no descriptor heap compiles at 6.5 once the attribute is gone.
* Measured upper bound: those two mechanical text changes alone — delete `[WaveSize(n)]`, and swap
  both heaps for declared resource arrays indexed dynamically (1024 entries, index `& 1023u`) —
  give **483/483 (100 %) at 6.5**, every stage included. So 6.5 is feasible, but it is a
  **binding-model rework, not a knob**.
* Patch surface for that rework (medium-to-large, ~2 days): the 8 heap-indexing sites
  (`emit.rs:1553, 2169, 2273, 2296, 2324, 2353, 2364, 2387`) → typed arrays per resource type (23
  distinct (heap, type) pairs per 253 programs) with clamped indices; `pso::abi_root_signature`
  (`pso.rs:596-598`) binding them as *aliasing* descriptor ranges over one shader-visible heap (the
  same T# is read as several types); and a 32-bit-CAS fallback for 64-bit atomics
  (`emit.rs:4855-4901`; 0/483 programs here).
* **Implemented (smallest version, default off): `XCL_SHADER_MODEL=6_5`.** Files changed, +/- lines
  vs the worktree tip (`pr572` @ 14d638a): `gpu/recomp/pso.rs` +32/-11 (new `sm65()`/`profile()`,
  used at 460, 476-478, 512, 514, 592; `console_to_hlsl` → `String`), `gpu/recomp/emit.rs` +19/-5
  (new `wave_size(lanes)` + the 5 `[WaveSize]` sites), `gpu/recomp/runner.rs` +14/-6 (gate 101-112;
  kernel 597/608), `shaders.rs` +11/-11 (`--recomp --compile N` uses the same profile),
  `gpu/recomp/tests.rs` +1/-1. 77/34 total — a **trivial knob worth exactly 37.5 %**, no more.
  Verified without a GPU: `cargo build --release --workspace` OK in 27.55 s (one pre-existing
  unrelated warning); then `xcl shaders shaders.rpf --recomp --compile 8` gives `8 OK, 0 errors` by
  default and `6 OK, 2 errors: … use of undeclared identifier 'ResourceDescriptorHeap'` with
  `XCL_SHADER_MODEL=6_5` (`raw\ab_66.txt`, `ab_65.txt`). Patch `H:\leonida\sm65_probe\sm65-final.patch`
  (17 703 B): `git apply --check` on a pristine 14d638a copy exits 0 and reproduces the built files
  byte-for-byte. Built in an isolated copy `sm65_probe\xcl-sm65` + `CARGO_TARGET_DIR=sm65_probe\target`
  because `H:\leonida\xcl` was held by `prtest` (its snapshots of my mid-flight edits:
  `prtest\sibling-wtree-pr487-163602.patch`, `sibling-wtree-pr488-164256.patch`).
* Not tested here (needs the GPU): whether a 6.5 device runs the `[WaveSize]`-free CS at the wave size
  it picks — XCL's `split_wave64`/`upper_lanes` forms check `WaveGetLaneCount()` at run time
  (`pso.rs:538-551`), so dropping the attribute is coherent, but that is unmeasured.
