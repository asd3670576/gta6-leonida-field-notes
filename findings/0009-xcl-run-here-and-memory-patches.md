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

Measured with `port\ag_probe.cpp` + `port\agility_matrix.ps1` rather than taken on faith:

| case | result |
|---|---|
| no `D3D12SDKVersion` exports | `C:\Windows\SYSTEM32\D3D12Core.dll`; asked for SM 6.6 → **highest 6.5** |
| exports `620` + `D3D12\D3D12Core.dll` (Agility 1.620.2) | `LoadLibrary("d3d12.dll")` → **1114 ERROR_DLL_INIT_FAILED** |
| exports `610` + Agility 1.610.2 in `D3D12\` | **1114** as well |
| exports present, `D3D12\` absent | **1114** |

So the OS really does need `ID3D12SDKConfiguration1`, which Windows 10 22H2 gained in
KB5029331 (build 19045.3393); we are on 19045.3324. We are **one cumulative update short** of
the requirement, and the pre-KB5029331 mechanism (the classic exe exports) is not a workaround
here — both Agility versions fail to initialise. Until that is closed, everything we measure
with `xcl run` runs with the shader recompiler disabled: the crash above is *not* one of the
crashes XCL's own reports describe, and the VRAM-side mechanisms (#345, #505-style pipeline
accumulation) cannot be reproduced on this box.

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

The sizing is worth spelling out because it is where "显存溢出" comes from on a card smaller
than an Xbox Series X:

- `config.rs:111`: with `uma_mb = 0` — which is what XCL wrote into our `xcl.toml` — an
  **`advanced` title-memory game gets `uma_mb = 4095`**, and `config.rs:27-28` says anything
  above 4095 is split into 4 GiB windows (`gpu::uma`).
- Our log line is the layout: `UMA: 3 sparse VRAM window(s) (12 GiB VA) + 512 MB coherent
  window at 0x400000000`, i.e. **3 × 4 GiB of sparse VRAM windows plus one coherent window that
  grows towards 4095 MB** (it climbed 1172 → 3371 → 3934 → 4530 MB across one run, and the
  learned target is stored in `cache/uma_coherent.txt` for the next run). 12 + 4 = **16 GiB**,
  the Series X's unified pool — with no relation to how much video memory the PC has.
- So on our 20 GB card, XCL's own accounting (`coherent … , sparse 7431 MB`) plus the driver's
  DXCache is enough to fill it, *with the shader recompiler switched off entirely*. The
  `20091/20480 MiB` sample was taken while another GPU program was running and should not be
  read as an exact XCL figure, but the 16 GiB sizing above is from the code and the run's own
  lines, and it is the mechanism.
- The lever exists but is undocumented for this case: `uma_mb` in the title's `xcl.toml`
  (values above 4095 are split into windows; `0` means "ask for the device's standard budget").
  Lowering it is the small-VRAM fix upstream's #345 reporter needed on their 6 GB card, and an
  automatic cap at the adapter's dedicated memory would be the friendlier version of it.

## What we did not claim

* We did not reproduce any of XCL's OOM reports; our run stops earlier, for a different reason
  (no SM 6.6). The patches are correctness/robustness work whose payoff is on the 16–32 GB
  machines those issues describe.
* The 450-line upstream analysis (`0010-xcl-approach-and-oom.md`) is a document read, not a
  run measured, except where this file says otherwise.
* Nobody has run XCL on 20 GB of VRAM per the issues we read, so our next runs — after the
  shader question is settled — are new data for #345 and #505 either way.
