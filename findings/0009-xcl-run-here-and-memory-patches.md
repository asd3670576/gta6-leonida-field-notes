# 0009 — Running XCL on the same package, and two memory patches we built and tested here

**Date:** 2026-11-24 · **XCL:** `ivall/xcl` @ `main`, cloned 2026-11-24 ~12:30 local
**Host:** Windows 10 Pro for Workstations 19045.3324 (22H2), Ryzen 9 5950X (16C/32T), 64 GB RAM,
RTX 3080 20 GB, driver 610.88 · **Package:** the verified GTA VI 1.0.2.1 set from 0001/0002

Why this finding exists: Leonida's upstream repository was deleted (it is now 404; our
successor clone and its port notes are 0008), and the project that *is* actively running this
title on PC is XCL — Rust, GPL-2.0-only, ~3.9k stars, 376 open issues, last push the same day.
See `0010-xcl-approach-and-oom.md` for the full read of its approach and its twelve distinct
memory-exhaustion mechanisms; this file is what we measured ourselves and what we changed.

## Building XCL without Visual Studio

`README.md:92-101` asks for `stable-x86_64-pc-windows-msvc` + the Windows SDK. This machine has
neither, and the GNU ABI works: rustup with `stable-x86_64-pc-windows-gnu` (Rust 1.100.0) plus the
MinGW-w64 from 0008 on `PATH`.

```
H:\leonida\port\setup_rust.ps1        # rustup-init, minimal profile, RUSTUP_HOME/CARGO_HOME on H:
H:\leonida\port\fetch_dxc.ps1         # DXC 1.9.2609, SHA-256 ad31b1fc…7e7f1 verified
H:\leonida\port\build_xcl.cmd         # cargo build --release --workspace
H:\leonida\port\test_xcl_patch.cmd    # build + the unit tests of the modules we touched
```

Whole workspace, release, from an empty `target`: **1 m 39 s**; incremental: 41 s.
`xcl.exe` = 110,159,371 B (release keeps debug info, `[profile.release] debug = 2`).
One thing to know: without the MinGW `Library\bin` on `PATH` the build fails with
`error calling dlltool 'dlltool.exe': program not found` — the same trap as 0008's `as.exe`.

## What our run did

`xcl run H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK` (`run_xcl.cmd` / `run_xcl_watch.ps1`):

- Recognised the package: `RockstarGamesInc.28872443D20A7`, `TitleId 7952987A`,
  `MicrosoftGame.Config: title memory Advanced, PLS 2048 MB`; `xcl inspect` reports
  `Console game: yes (imports d3d12_xs.dll)`, 587 imports from 68 DLLs, one stub
  (`xmem.dll!XMemIsToolsMemAvailable`).
- Built the whole D3D12.X stack: 3 sparse VRAM windows (12 GiB VA) + a 512 MB coherent window,
  console descriptor heaps (1 245 184 view slots), display targets `3840x2160 format 28`,
  `PresentX — the title presents its own frames`, `sparse windows: 512 submits, 1286 MB of CPU
  writes uploaded, 12731 tiles mapped`.
- The title got its own debug context written: `Game State: Game Init`, `Frame: 0`,
  `Streaming Requests: 22`, `TileHeap: used (174Mb) - total (6236Mb)`,
  `Version: 930.048.020-vb_sub_story`, `Conole Type: Anaconda`.
- Ended 37 s in: `unhandled exception 0xc0000005 in game_scarlett_master.exe+0xb5a5f8
  (read at address 0x68)` with the game's frames `+0x18194c7, +0x75b30f8, +0x1dc5cb4,
  +0xb5ac26, +0x71bfd40, +0x75de450`.

Cross-check with our own shader work: `xcl shaders …\shaders.rpf` prints
`RPF9 package 392.6 MB, 26503 shader records`, `FSSM: 26698, programs: 26698` — the same
26 503 / 26 698 counts we carved and translated on the Leonida side (0002, 0007). Two
independent toolchains agree on the pack, which is a nice confirmation of both.

## Why the run is not comparable to XCL's best reports

XCL's preflight on this machine:

```
ERROR: NVIDIA GeForce RTX 3080 (20253 MiB VRAM): no SM 6.6 (Agility SDK unavailable:
ID3D12SDKConfiguration1 unavailable (update Windows 10 to 22H2 KB5029331+): 不支持此接口
(0x80004002)) (has 6.5): shaders cannot run
```

Measured with `port\ag_probe.cpp` + `port\agility_matrix.ps1` rather than taken on faith, and
then re-measured once a confound of our own was removed:

| case | result |
|---|---|
| no `D3D12SDKVersion` exports | `C:\Windows\SYSTEM32\D3D12Core.dll`; asked for SM 6.6 → **highest 6.5** |
| exports `620` + `D3D12\D3D12Core.dll` (Agility 1.620.2) | `LoadLibrary("d3d12.dll")` → **1114 ERROR_DLL_INIT_FAILED** |
| exports `610` + Agility 1.610.2 in `D3D12\` | **1114** as well |
| exports present, `D3D12\` absent | **1114** |

**Those rows were not yet a fair test of the classic mechanism, and we corrected them.**
The probe now prints its own export directory, and that showed GNU ld assigning PE ordinals
alphabetically for `__declspec(dllexport)`:

```
self export: D3D12SDKPath     ordinal=1  value=0x5c3231443344       <- the string "D3D12\"
self export: D3D12SDKVersion  ordinal=2  value=0x314433440000026c   <- 0x26c = 620
```

The D3D12 runtime reads the version from **ordinal 1**, so it was reading the string's bytes as
a version number. MinGW's `dlltool` would not emit both entries from a `.def` ("Syntax error in
def file", exit 0, one export written), so `port\fix_exports.py` rewrites the export directory of
the linked image: `AddressOfFunctions[0]` gets the version's RVA and the two name ordinals are
swapped to match. With that verified in the same process (`D3D12SDKVersion ordinal=1`), the
matrix was re-run:

```
Agility 1.620.2.0.20261106.5   version_ordinal=1  err 1114
Agility 1.610.2.0.230420-…610  version_ordinal=1  err 1114
Agility 1.608.2.0.221212-…608  version_ordinal=1  err 1114
```

Developer Mode is already on here (`HKLM\…\AppModelUnlock!AllowDevelopmentWithoutDevLicense = 1`),
so that is not the missing piece either. Conclusion, stated as the strong claim it now is:
**the OS really does need `ID3D12SDKConfiguration1` on this machine** — Windows 10 22H2 gained it
in KB5029331 (19045.3393) and we are on 19045.3324, one cumulative update short. The pre-CU
mechanism is not a workaround, at least not for the SM 6.6-capable Agility releases (≥ 1.600).

Until that is closed, everything we measure with `xcl run` runs with the shader recompiler
disabled: the crash above is *not* one of the crashes XCL's own reports describe, and the
VRAM-side mechanisms (#345, #505-style pipeline accumulation) cannot be reproduced on this box.

Memory attribution caveat, recorded deliberately: the first sampled run showed
`vram_used 20091/20480 MiB` and `free physical 2937 MiB` 20 s in. Another GPU-heavy program
(STRATA) was running at the time, so **we do not claim those numbers for XCL**. Free counters
measured later with nothing else running: 125.9 GB commit available, 52.9 GB physical free.
`watch_xcl_mem.ps1` now samples commit charge, thread count and XCL's own
`coherent N/M MB, sparse K MB, B blocks` line into one CSV so the next run is unambiguous.

## Two patches we wrote, built and tested here

Diff: `port\xcl-mem-patches.diff` (8 564 B, three files). Build green, unit tests:
`17 passed; 0 failed` — including the new one — and the two pre-existing lazy-page tests still
pass, so the first-touch fault path is unchanged.

**1. `hle/kernelx/lazy.rs` + `eh.rs` — a failed lazy commit must not be silently lost (upstream #467, which duplicates #487/#488/#502).**
`commit()` used to do `if !g.remove(&page) { return false }` and only then `VirtualAlloc(MEM_COMMIT…)`:
when the commit failed near the system's commit limit (#333 measured 0.44–0.98 GiB of headroom
left on 16 GB machines), the page had already left `LAZY`, so the next access was not retried,
the vectored handler returned `EXCEPTION_CONTINUE_SEARCH`, and the title died with a bare
`0xc0000005` that reads like a wild write. Now the page leaves `LAZY` only after a successful
commit, and the failure is counted (last page + `GetLastError()` in atomics, no allocation or
logging inside the handler); `eh.rs` appends one clause to the unhandled-exception line:

```
| lazy page commit failed 3 time(s), last 0x1a2b3c0000 err 1455 ERROR_COMMITMENT_LIMIT
```

New test `a_failed_commit_keeps_the_page_lazy_and_says_so` uses a released address to stand in
for a refused commit and asserts the page is still lazy, that `ensure()` does not swallow it,
and that the note names the error.

**2. `gpu/recomp/dxc.rs` — memory-aware default for the compile-thread count (upstream #542).**
`compile_threads()` returned `cores - 1` (31 here; 31 on the reporter's i9-14900K/32 GB).
`dxc.rs:376-377` itself says a big translation takes ~0.7 GB, so the first cold-cache wave can
start 31 × 0.7 GB before `wait_for_memory` gets a chance to throttle anything — which is exactly
#542's report ("the first runs made the whole machine unresponsive", 1.6–3.0 GB free after 3–6
minutes, `XCL_DXC_THREADS=4` needed to keep it alive). The default is now additionally capped by
the commit available when XCL starts, one worker per GB, `XCL_DXC_THREADS` still wins, and when
the cap bites, one log line says why. On this machine (125.9 GB commit free at start) it changes
nothing: `min(31, 125) = 31` — the patch costs no throughput where memory is ample, which is the
point #542's author made about `title_memory_mb` not helping.

## The console's 16 GiB GPU pool, mapped onto a PC's VRAM

The sizing is worth spelling out because it is where "runs out of memory" comes from on a card
smaller than an Xbox Series X — with one caveat about what XCL's own log lines mean.

- `config.rs:111`: with `uma_mb = 0` — which is what XCL wrote into our `xcl.toml` — an
  **`advanced` title-memory game gets `uma_mb = 4095`**, and `config.rs:27-28` says anything
  above 4095 is split into 4 GiB windows (`gpu::uma`).
- Our log line is the layout: `UMA: 3 sparse VRAM window(s) (12 GiB VA) + 512 MB coherent
  window at 0x400000000` — 3 × 4 GiB of sparse windows plus a coherent window that grows towards
  4095 MB (it climbed 1172 → 3371 → 3934 → 4530 MB within one run). **12 + 4 = 16 GiB, the
  Series X's unified pool, chosen from the title's memory class and not from the adapter.**
- **Do not read `sparse 7431 MB` as 7.4 GB of anything physical**: it is reserved *address space*
  (`gpu/uma.rs:370-373`). What is really committed per sparse page is host RAM
  (`kernelx.rs:227-233`) **plus** a 64 KiB video-memory tile handed out of 64 MiB pool heaps
  (`d3d12x/sparse.rs:35-36, 571-599`) — our run had 12 731 tiles mapped, ≈796 MiB of VRAM
  duplicated on top of ≈796 MiB of host RAM.
- The `20091/20480 MiB` VRAM sample and the `2937 MiB free RAM` sample were taken while another
  GPU program (STRATA) was running, so they are not XCL's footprint; with the sparse path
  duplicating each page and the coherent window pinned high (below), 20 GB is still the
  tightest constraint on this machine, and `d3d12x/vram.rs:303` never returns its `Pages` pool
  heaps, so whatever peak the run reaches stays allocated.
- Two levers, one of which does **not** do what it looks like it does:
  - `uma_mb` alone does not shrink the coherent window once XCL has learned one: with
    `cache/uma_coherent.txt` holding 4 770 168 832 (4549 MiB, from our run),
    `gpu/uma.rs:170, 739` computes `size.min(coherent.max(512 MiB))` = 4095 MiB committed
    regardless of `uma_mb`. Pin it with **`XCL_COHERENT_MB`** (`gpu/uma.rs:679-681`) or delete
    the cache file. The adaptive value is written only when it grows
    (`uma.rs:711-724`) and is gated on 17 GiB of free **commit**, not free RAM (`uma.rs:687-699`).
  - **`title_memory_mb`** in the title's `xcl.toml` is the lever that shrinks both sides: XCL
    reports it as the title's memory budget (`config.rs:117-123`, `kernelx.rs:753`) and the
    engine sizes its own streaming pools from it.
  - `XCL_VRAM_ARENAS=1` switches off the tiled path (`vram.rs:647, 662`) and allocates whole
    placement ranges as arenas instead; upstream's own history with it is 15 GB of arenas in 2 s
    and a device removal (`vram.rs:14-24`, `HANDOFF.md:1791-1793`). Our run made 31 MB of arenas,
    so on a 20 GB card leave it off.

Full pool-by-pool reading, with file:line for every claim:
[`0012-xcl-memory-model.md`](0012-xcl-memory-model.md).

### Verified: `XCL_COHERENT_MB` is the lever, and memory is not what stops our run

A second run with `XCL_COHERENT_MB=512;XCL_ACTIVITY=1` (the learned
`cache/uma_coherent.txt` of 4549 MiB would otherwise have forced a 4095 MiB coherent window):

- XCL's own accounting stayed at **`coherent 83/512 MB, sparse 7431 MB, 83 blocks`** — the pin
  works, exactly as `gpu/uma.rs:679-681` says, and the 4 GiB coherent commitment is gone.
- The run still ended at the same place: `unhandled exception 0xc0000005 in
  game_scarlett_master.exe+0xb5a5f8 (read at address 0x68)`, same frames.
- Its `report.json` says why the GPU side is inert while this machine is on 19045.3324:
  `"recomp_programs": 0, "recomp_dxc_ok": 0` against `unique 1274, submitted 3542` shaders and
  748 551 RDNA2 instructions decoded — the recompiler saw the title's GPU code and did not
  recompile a single program.

So on this machine memory pressure is **not** the limiter: with the coherent window cut from
4095 to 512 MB the title dies in the same instruction. The limiter is the missing Shader Model
6.6. The two-sided cost of the sparse/coherent design (0012) is what will bite once shaders do
run, and it is what upstream's #345/#505 reporters met on smaller cards and smaller commit.

## What we did not claim

* We did not reproduce any of XCL's OOM reports; our run stops earlier, for a different reason
  (no SM 6.6). The patches are correctness/robustness work whose payoff is on the 16–32 GB
  machines those issues describe.
* The 450-line upstream analysis (`0010-xcl-approach-and-oom.md`) is a document read, not a
  run measured, except where this file says otherwise.
* Nobody has run XCL on 20 GB of VRAM per the issues we read, so our next runs — after the
  shader question is settled — are new data for #345 and #505 either way.
