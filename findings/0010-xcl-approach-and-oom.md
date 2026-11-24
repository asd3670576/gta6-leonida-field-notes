# 0008 — XCL (`ivall/xcl`): how it works, and the memory/OOM picture

Notes compiled 2026-11-24 (Asia/Shanghai) from the repository `ivall/xcl` @ `main` (tarball of
`refs/heads/main`, ≈ `6025201`/`18c105a` era, downloaded 2026-11-24 04:30Z) plus issues/PRs read
through the GitHub REST API. Everything below is quoted from that repo unless marked
**unverified**. No files under `H:\leonida\Leonida-continued` or `H:\GTA6` were touched; git was
not used (tarball + API only).

Our machine for the recommendations: **Windows 10 Pro for Workstations 19045**, Ryzen 9 5950X
(16C/32T), **64 GB RAM**, **RTX 3080 20 GB** (Ampere, wave32-only, mesh tier 1), driver **610.88**,
~1.3 TB free disk. Package: `game_scarlett_master.exe`, `GTA6.Xbox.v1.0.2.1-CYBERLEEK`.

---

## (a) What XCL is, and how it differs from the Leonida approach

### What it is

* "Runs Xbox Series X|S (GDK) game files on a Windows PC **without CPU emulation**: the game's
  x64 code runs natively and XCL stands in for the console libraries the PC does not have
  (`kernelx.dll`, XGameRuntime, `d3d12_xs.dll`, …) – in the spirit of Wine/Proton. The console's
  GPU code (RDNA2 machine code) is recompiled into PC shaders (HLSL → DXIL)."
  — `README.md:6-9`
* Design doc: single process `xcl.exe` = launcher + own PE loader + resolver + VFS + HLE modules
  (`docs/specs/2026-11-20-xcl-design.md:98-115`). **Approach B (own PE loader)** was chosen over
  approach A (**DLL replacement, "like WinDurango"**) precisely because with A "one missing
  function = the game does not start", while with B "the game always gets as far as it can;
  a full report of what is missing after the 1st run" (`docs/specs/…:80-91`). The launcher starts
  a second copy of itself as the host (`main.rs:48-50`, `launcher.rs:439`).
* Data-driven import routing (HLE / Windows / automatic logging stub) + `report.json` after every
  run listing `called_stubs`, `stubbed_imports`, `d3d12`, `shaders`, `dxc`, `dstorage`,
  `xgameruntime`, `crash` (`report.rs:44-83`, `build()` at `report.rs:98-155`).
* Scale of the implementation (file sizes from the tree): `hle/d3d12x/list_x.rs` 172 KB,
  `hle/d3d12x/real.rs` 277 KB, `hle/kernelx.rs` 115 KB, `gpu/recomp/emit.rs` 298 KB,
  `gpu/recomp/tests.rs` 403 KB, `gpu/rdna2_spec.rs` 751 KB (generated ISA tables).
* Status per `README.md:11-26`: Minecraft Preview and Unicorn Overlord fully playable; Fortnite and
  XDefiant work as far as their (dead) online services allow; "**A newer retail game**" (never
  named in the README) "starts in ~4 s, runs at a steady 30 fps without a crash, shows its menus
  and goes on past the first one to its settings; fits a 32 GB machine (~15 GB committed in the
  menus); gameplay not reached yet; its minimap mesh pipelines are refused".
* That unnamed retail game **is our title**: the exe name `game_scarlett_master.exe`
  (`HANDOFF.md:261`), the package id `RockstarGamesInc.28872443D20A7` / TitleID `7952987A`
  (#333 comment 4, #505 body), version 1.0.2.1 (#232, #298, #333), and one contributor's smoke
  block literally reads `title: GTA6.Xbox.v1.0.2.1-CYBERLEEK` (#156 comment 13).
* Repo facts at fetch time (`api.github.com/repos/ivall/xcl`, 2026-11-24 ≈05:29Z): 4 267 stars,
  551 forks, 425 open issues, ≥300 open PRs (3 pages of 100 returned), version 0.1.0, created
  2026-11-20, GPL-2.0-only, `main` pushed 2026-11-24T05:24:11Z.

### The memory model it builds (this is what the OOM fights are about)

1. **Title memory budget**: `title_memory_mb` = 0 → the device standard budget
   **13 824 MiB Series X / 8 192 MiB Series S** (`config.rs:20-22`, `title_memory_budget_mb()`
   `config.rs:116-123`, defaults `config.rs:160-190`). Mode `auto` reads `anacondaMemory` /
   `lockhartMemory` from the game's `MicrosoftGame.Config` (`config.rs:83-91`, `manifest.rs`).
2. **Unified memory (`gpu/uma.rs`)**: D3D12 can only open a heap from an address below 4 GiB, so
   title graphics memory is split into **up to 4 windows of ≤ 4095 MiB** (`MAX_SIZE = (4096<<20) -
   0x10000`, `MAX_WINDOWS = 4`, windows 4 GiB apart, base 16 GiB aligned; `uma.rs:24-29`,
   `HANDOFF.md:1065-1080`). The window of an address is `(addr >> 32) & 3`; **every memory access
   of a translated shader becomes a `switch` over the window UAVs** unless there is only one
   window (`HANDOFF.md:1075-1079`, `README.md:110-115`, cost measured in #156 and #680).
3. **Sparse vs coherent windows**: since PR #40 the title's GPU allocations live in **sparse
   windows 0..2** (each a 4 GiB reserved GPU buffer whose 64 KiB tiles are mapped onto video-memory
   pool heaps as pages are committed, tile size `TILE = 0x10000`, pools `POOL_TILES = 1024`
   = **64 MiB** (`sparse.rs:34-36`)), while **window 3 is a coherent, fully committed system-RAM
   window** (XCL's arena pool, readback/write-back heaps; `HANDOFF.md:1423-1430`,
   `uma.rs:667-696`). Log signature in issue reports: `coherent 3998/4095 MB, sparse 7445 MB`.
   The coherent window's size comes from what the title asked for in the **previous run**
   (`<data>/cache/uma_coherent.txt`) + 512 MB, capped at one window, and it is only given at all
   if ≥ 17 GiB of commit is free at start (`uma.rs:673-699`; the warn line
   `UMA: … MB of commit free, under 17408 MB …`).
4. **Physical pages + lazy homes**: the console's physical-page API (`XMemMapPhysicalPagesScatter`)
   is emulated; a page home that is still all zero is mapped as **reserved address space only** and
   committed by a vectored handler on first CPU touch (`hle/kernelx/lazy.rs:1-11`, `mark/ensure`
   at `:76-101`); kernel calls don't fault, so ReadFile/DirectStorage destinations are committed
   eagerly via `lazy::ensure` (`dstorage.rs:726`).
5. **Video memory for GPU-owned targets**: render/depth/UAV targets placed at console addresses are
   **reserved (tiled) resources on 64 KiB pages of video memory**, one page per page of the title's
   address, shared by every target there, tiles returned to the 64 MiB pools after 2 s idle
   (`vram.rs:160-168`, `PAGE = 0x10000`, `POOL_PAGES = 1024`, `IDLE = COOL = 2 s`;
   `HANDOFF.md:1786-1793`). Only what the driver refuses to make reserved (D32S8/R32G8X24, MSAA)
   still uses **arenas** (default heaps per address range), unless `XCL_VRAM_ARENAS=1`
   (`vram.rs:647,662`).
6. **WDDM reality that drives most of the OOM reports**: "Every allocation of video memory is
   charged to the process's commit by WDDM, so video memory counts against RAM + page file"
   (`HANDOFF.md:1785-1786`). Also `OpenExistingHeapFromAddress` requires the region to be
   **fully committed** (`HANDOFF.md:1358-1360`), and a heap over a file mapping costs its full
   commit even from `SEC_RESERVE`-style intent (`HANDOFF.md:1641-1649`).

### GPU / API translation

* RDNA2 → HLSL → DXIL: `gpu/rdna2.rs` (+ generated `rdna2_spec.rs`), `gpu/recomp/{emit,dxc,mod,pso
  ,runner,mesh_wave,mesh_dispatch,upper_lanes,x64_masks}.rs`. 100 % of a retail pack:
  "all 26 698 RDNA2 programs (26 503 records) of its shader pack become HLSL; random samples
  compile to DXIL with 0 errors" (`README.md:30-31`).
* Mesh/NGG and geometry run as "a compute pass plus a mesh pass", so **a GPU without mesh shaders
  draws none of them**; on 32-lane GPUs (NVIDIA) "console wave64 compute, geometry and mesh
  programs run as two 32-lane halves that exchange masks and lane values
  (`docs/wave64-on-wave32.md`) – slower than 64-lane waves" (`README.md:110-115`).
* D3D12.X "ListX" console API: console vtable slots adopted/translated (`device_x.rs`,
  `list_x.rs`, `bind.rs`, `console_list.rs`, `guard.rs`, `layout.rs` + `hle/d3d12_layout.rs`
  generated from the console headers); all console view heaps share **one
  shader-visible PC heap of 1 000 000 view descriptors** (`hle/d3d12x/console_heap.rs:16`, the cap at `:140`, its log line at `:152`;
   issue #575 reads that same size back from the driver's buffer allocation); console command lists
  recorded in console format are replayed on PC lists (`HANDOFF.md:1332-1337`).
* Ray tracing: the game's own `XboxBvhBuilder` builds BLAS/TLAS on the PC GPU; RDNA2 BVH
  instructions emulated in shaders (`README.md:70`).
* Audio: XAudio2 → system XAudio2.9, Opus `0x704F` via `MSOpusDecoder.dll`, XMA1/XMA2 in Rust;
  APU/SHAPE (`acphal.rs`) with `chad.dll` (XDsp) still `E_NOTIMPL` in main (#156 Fix 1 asks to
  route it to `acphal`).

### Build requirements (README §Building and usage, `README.md:92-115`)

* Windows 10/11 x64; Rust `stable-x86_64-pc-windows-msvc`; Windows SDK.
* **DXC**: `dxcompiler.dll` + `dxil.dll`, looked up in `Windows Kits\10\bin\<version>\x64`,
  next to `xcl.exe`, or in `%XCL_DXC_DIR%`. "**DXC 1.8 or newer is recommended**"; the same SDK
  folder may hold **1.7.2308 or 1.8.2502 depending on revision**; "DXC 1.7's DXIL was 2–2.7×
  the size of 1.9's for translated compute programs and took an NVIDIA driver 1.4–2.2× as long to
  build pipelines from (#156)" (`README.md:103-109`). `xcl run` prints the DXC it loaded;
  `report.json` has it under `dxc`.
* **GPU**: D3D12 with **Shader Model 6.6 and mesh shaders**; developed on AMD RDNA4.
* **System XGameRuntime** `System32\xgameruntime.dll` (Windows / Gaming Services); without it
  dialogs/text entry/invites/streaming are missing but XCL's own task queues/async/networking are
  used (`preflight.rs:93-95`).
* **Windows 10**: "on Windows 10 (22H2 **KB5029331+**), inbox `D3D12Core.dll` stops at SM 6.5;
  place the Microsoft D3D12 Agility SDK (`D3D12Core.dll`, plus `d3D12SDKLayers.dll` for
  `XCL_D3D12_DEBUG=1`) in a `D3D12\` folder next to `xcl.exe`, directly next to `xcl.exe`,
  in `%LOCALAPPDATA%\XCL\D3D12\`, or point `%XCL_D3D12_DIR%` at it" (`README.md:96-101`).
  The loader requires `ID3D12SDKConfiguration1::CreateDeviceFactory`, and if that interface is
  missing the message is "update Windows 10 to 22H2 KB5029331+" (`agility.rs:3,11-17,273`).
  Contributor runs use Agility **1.616.1** (#139) and **1.620.2 / `D3D12SDKVersion = 620`**
  (#42 comments 7, 64, 69; #572, #641).
* Optional decoders: **BCPack is NOT in main** — `dstorage.rs:29` "BCPack and other console formats
  are refused", refusals counted per mode and reported in `report.json → dstorage`
  (`dstorage.rs:124-222`), with `E_DECOMPRESSION = 0x89240030` (`dstorage.rs:64`).
  `XCL_DSTORAGE_BCPACK_FILL=1` fills a refused destination with solid BCn blocks so streams that
  wait on BCPack show where they are; the request still fails (`dstorage.rs:226-230`).
* No `rust-version` pin in `Cargo.toml`; `[profile.release] debug = 2` ("keep full symbols in
  optimized alpha builds", `Cargo.toml:10-13`, merged as #713).
* Test/build entry: `.\scripts\test.ps1` (= `cargo build --workspace` + `cargo test --workspace`)
  (`README.md:148-150`); `scripts/smoke.ps1` emits the `xcl-smoke v1` block that every PR must
  paste twice (main + head) per `CONTRIBUTING.md:21-30`.
* WinDurango is **reference only, no code ported** (LGPL-3.0 vs GPL-2.0-only)
  (`README.md:166-169`, `CONTRIBUTING.md:164`); AnyPS5 logic is ported with annotation
  (`THIRD_PARTY.md:9`). **No mention of Leonida anywhere in the repo** (grep over the whole tree) —
  the two projects are independent.

### What that means for our Leonida blocker (interpretation, not repo fact)

* Our symptom — a guest `int3` right after a burst of `XMemVirtualAlloc` — is the *shape* of
  failure approach A produces: one unimplemented/oddly-answered console call and the title traps.
  XCL's structural answers, all present in main: (i) automatic logging stubs instead of a hard
  failure, (ii) `stub_returns` in `xcl.toml` to answer a specific stub with a value
  (`config.rs:42-43` and the generated header `config.rs:194-198`), (iii) `report.json`'s
  `called_stubs` / `unknown D3D12.X slots` list (`README.md:133-134`).
* XCL's `XMemVirtualAlloc` (`hle/kernelx.rs:632-635`) accepts console `XALLOC_ATTRIBUTES`, and a
  plain `VirtualAlloc` placeholder exists in `hle/kernelx/placeholders.rs` (`HANDOFF.md:1732`);
  graphics-typed allocations go into the UMA windows / sparse windows (`kernelx.rs:302-317`), and
  XDefiant-style 8 GiB `MEM_RESERVE|MEM_LARGE_PAGES` reservations get addresses in sparse
  windows 1–3 (`HANDOFF.md:1614-1616`). Worth diffing our handling of attributes
  `0x20402000`-style values against XCL's `PAGE_GRAPHICS_ANY = 0x7_F800` (`kernelx.rs:362`).
* **Unverified:** whether Leonida implements the sparse/coherent window split, the 4 GiB window
  `switch`, and the physical-page-home laziness at all. Those three are what make the GTA VI
  allocation pattern survivable on a 32 GB machine.

---

## (b) Memory-exhaustion mechanisms — one row each, with issue/PR numbers and status

Status column = state as seen through `api.github.com` on 2026-11-24 (open PRs ≠ merged;
"merged" verified from `/commits` subjects or a maintainer comment).

| # | Mechanism | What actually runs out | Issues / PRs | State |
|---|---|---|---|---|
| M1 | **Host commit limit (RAM + page file)** | `CreatePlacedResourceX` → `0x8007000E`; title `int3` at `+0x193e00f`; 3 of 4 measured crashes had **0.44–0.98 GiB of commit headroom left** on a 16 GB machine (system commit 58.51/59.07 GiB, process private 34.59 GiB, working set only 0.93 GiB) | #333 (open, 8 comments, incl. 16 GB/12 GB/8 GB/16 GB-card data points); #542 (open); #467 (open); #194 (open PR: adds the memory line that would attribute it); #632 (open PR: coherent window sizing) | open; #194 unmerged |
| M2 | **WDDM charges commit for every video-memory allocation** | "Every allocation of video memory is charged to the process's commit by WDDM, so video memory counts against RAM + page file"; doubling of physical-page homes: an early run "took **28.7 GB of commit**" because ~5.7 GB of mapped pages were committed **twice** (copy + home) and every home also had video tiles (126 pools × 64 MB) | `HANDOFF.md:1740-1746` (fixed → "16 - 17 GB, first frame at 3.6 s"), `HANDOFF.md:1785-1798` | fixed in main (sparse-first + `lazy.rs`) |
| M3 | **DXC compile fan-out** (worker count × per-compile growth) | default `compile_threads()` = logical − 1 (31 on i9-14900K); a retail translation can take ~0.7 GB in DXC (typically 0.1–0.3 GB); 32 GB machine "nearly took Windows down from memory, twice"; one 1589-instruction shader grew **38 GB of committed memory** and killed the user's session | `dxc.rs:375-387`; #542 (open) → #572 (open PR, memory-bounded default); #113 (merged `f311ca5`, gate `6 GB + 1 GB × running`, threads → all cores − 1); #139 (open PR: gate counted twice, stampede after 60 s, CAS race, 300 MB instead of 1 GB); #198 (open: coordination) | mixed |
| M4 | **Driver pipeline compiles (nvgpucomp64 / amdxc64)** | one 4-window split-wave64 program ≈ 749 KB DXIL → **130–143 s** and **12.0 GiB peak commit** during the *driver* build (RTX 5070 Ti, driver 610.74); Ampere: 298 KB → 10.5 s, 613 KB → 31 s, 863 KB → 55 s, ~1.1 MB → >2 min per pipeline, one creator; NVIDIA graphics PSO queue "never finishes" (2 428 pipelines queued for 10+ min); `wait_for_commit` spins until **3 GiB free commit** holding a single `BIG_COMPILES` slot, so on 32 GB/`pagefile`-limited boxes each 1 MB CS "took ~400 s" | #156 (open, 15 comments of measurements); #214 (open PR: bound driver concurrency, `XCL_DRIVER_COMPILE_THREADS`); #567 (open PR: 5 s grace so it cannot deadlock); #680/#187 (heap-indexed windows: driver **9–10× faster**, 329.9/363.0/341.8 s → 41.7/40.3/40.5 s); #634+#636 (**merged**: driver blob kept in memory ≤ 512 MiB and on disk), #690 (merged: pipelines an earlier run used are built ahead) | open + partially merged |
| M5 | **Live pipeline objects accumulate** | on a **64 GB / 145 GB-commit-limit** machine, after the title's watchdog was removed, private bytes went 25.7 GB (317 s) → 44.9 (378) → 78.0 (409) → **138.9 GB (442 s)** while 575 compute + 285 graphics pipelines were built; a separate test that built compute pipelines ahead and kept them went **17 GB → 111 GB over 1 067 pipelines (~88 MB each)**. "I have not yet split this between the driver's live pipeline objects, compiles in progress and XCL's own copies." | #505 comment 24 (shelbykb2); related #267, #533, #539 (bounded pipeline waits, open) | un-attributed, no dedicated issue found |
| M6 | **Local video memory (VRAM) exhaustion: sparse tile pools** | 6 GB card: `coherent 3998/4095 MB, sparse 7445 MB` needs 7 445 MB of tiles > 5 966 MiB → `CreatePlacedResourceX` `0x8007000E` 1 243–1 434×/run at ~212 s, then the title's own `int3`; with `XCL_VRAM_ARENAS=1` instead → `CreateHeap(0x4000000 …)` refused + `sparse windows: no video memory for more tiles (0x8007000E)`, then an AV inside `nvwgf2umx.dll` | #345 (open; 1 comment: **on a 12 GB card the video-memory OOM does not happen**) | open |
| M7 | **VRAM: one PC copy per texture placement, never shared or released** | kept-in-step title textures: 35 553 kept textures = **12.7 GB of copies covering only 4.0 GB** of title memory → VRAM +0.35 GB/s → `0x887A0007` device reset at 106/116 s on a 16 GB card; also 62 000 live "targets" created by `real::resource_at` and never released (`MADE` map, `real.rs:2070-2072`) | #248 (**closed as completed**; the fix landed as #269 + #288/#484/#486/#490/#602/#451/#435); still open: #292 (retire overwritten textures + `ResourceAtCache` cap 65 536), #640 (open, `XCL_PAGE_BUDGET_MB` LRU), #782 (open: budget must see textures in use by their T#), #496/#532/#483/#522/#551 (open lifecycle/CPU-side fixes), #320 (open: 8 GB feasibility) | partially fixed |
| M8 | **Target-page pools keep idle/cooling tiles; arenas of the driver-refused formats** | "15 GB of arenas in 2 s, 18 GB of local video memory on a 16 GB card, then the device was removed"; arenas for D32S8 still 2.8 GB (one per 256 MB of addresses); measured pool slack is small: idle+cool waste ≤ 224 MB on an 8 GB card, so reuse under pressure "would not save this card" | `HANDOFF.md:1790-1793,1813-1815`; #225 (**merged**: exact-size arenas, scenario peak 7.25 GB → 2.15 GB; 14× D32S8 4K arenas 3.76 GB → 585 MB); #490 (merged: idle sweep); #447/#617/#489/#712/#770/#768/#614 (open tests of reserved-resource tiling vs the driver) | mostly fixed |
| M9 | **Leaked / double-committed lazy pages; silent commit failure** | `lazy::commit` removes the page from `LAZY` **before** `VirtualAlloc(MEM_COMMIT)`, so a commit that fails with `ERROR_COMMITMENT_LIMIT` (1455) leaves the page non-lazy → the next fault returns `EXCEPTION_CONTINUE_SEARCH` → the title dies as a plain `0xC0000005` "on a page that stays `MEM_RESERVE`", and `lazy::ensure` (DirectStorage destinations) fails as `0x89240009` with no log | #467 (open) with three competing open PRs **#487 / #488 / #502** (all three merge cleanly; #488's new test is flaky on two machines; #502 logs from inside the vectored handler); #244 (**merged**: lost-race retry, test `threads_first_touching_one_lazy_page_together_all_go_on`); #454, #561, #629, #631 (open) | open |
| M10 | **UMA exhaustion at run time (per-draw data)** | each draw allocated 3 × 64 KiB grains in UMA → the 2 GB window filled in seconds → "unified memory is full", most draws skipped (16.7 M draws, 0 skipped after the `uma::Arena` fix); a title committing all of UMA at start left no room for draw args | `HANDOFF.md:1400-1403`, `HANDOFF.md:1426-1430` ("no room in UMA"), `uma.rs:51-58` (XCL's own 64 MiB `POOL`, kept out of the title's reach) | fixed |
| M11 | **Layout/detile/hash staging copies on the CPU side** | each `xg::Texture` built its own tiling `Layout` with 65 536-entry high-coordinate tables = **256 KiB of CPU memory per live tiled texture**; every upload copied the texture's memory into a fresh zeroed buffer before hashing+detiling; per-texture D3D12 upload objects | #435 (**merged**: tables sized to one period, 256 KiB → 4–128 B), #602 (**merged**: detile+hash in place), #451 (**merged**: reused upload buffer/list/fence per queue; upload buffer grows to `BATCH_BYTES` 256 MB and is never shrunk), #486 (**merged**: skip unchanged uploads) | fixed |
| M12 | **dxil-spirv (vkd3d-proton) runaway** — only on the Wine/vkd3d path | "a title PSO thread got stuck in vkd3d-proton's DXIL→SPIR-V conversion (`dxil_spv::CFGStructurizer`) of one ~284 KB translated compute program; it grows ~500 MB/s until RAM runs out or the title's watchdog fires … reproduced with the standalone dxil-spirv CLI (**20 GB in 60 s**)" | #575 (open; the RADV page-fault half is the T# heap-index bug, draft PR #610), #764 (open test PR) | open, Linux-only |

**Which mechanisms our 64 GB / 20 GB box does *not* hit (or hits much later)**

* M12 (dxil-spirv) — **not applicable**: native Windows D3D12, no vkd3d-proton.
* M1 — *very* unlikely at the same wall: with 64 GB RAM and a fixed page file sized from our 1.3 TB
  free disk (say 128 GB), the commit limit is ~190 GB vs the 59–70 GB limits in #333/#505. The
  17 GiB coherent-window gate (`uma.rs:699`) passes, so we get the full 4 095 MB coherent window
  from the second run (or from the first, with #632). **Caveat:** M5 shows 138.9 GB is reachable on
  a 64 GB box, so "no OOM" is not guaranteed — but we can watch it and be the machine that
  attributes it.
* M3 — the `wait_for_memory` gate (`dxc.rs:410-433`, wants 6 GB + 1 GB × running **free commit**)
  will essentially never slow us: with ≥ 100 GB free commit, all 31 DXC workers run at once. MonkeyPython
  measured that on GTA VI the growth is **thread-count-independent**: 15 threads → 39.48 GB,
  `XCL_DXC_THREADS=4` → 39.89 GB (#542 comment 3). So we are the machine that can *decouple*
  "compile pressure" from "title memory growth".
* M4's commit-driven part (`wait_for_commit`, 3 GiB free) also stops applying; the *time* part
  (minutes per large DXIL on NVIDIA) applies to us in full — Ampere numbers in #156 comment 9 are
  the closest published match to an RTX 3080.
* M6 — **does not apply**: `sparse 7445 MB` + pools fit in 20 GB (12 GB already sufficed, #345
  comment 1). M7/M8 — apply but with ~1.6× more runway than a 12 GB card; the published stalls were
  at 13.7–14.4 GB local video memory (#640, #505 comment 20, #156 comment 11) i.e. just past our
  20 GB we should still see the same growth, ~60–90 s later.
* M2, M9, M10, M11 — mostly already fixed in current `main` (see rows), so they should not appear
  in our runs at all; if they do, that is a finding.

---

## (c) Knobs: every documented env var / config key, with source, and what we should set

### In current `main` (verified in the tarball)

| Knob | Source (file:line) | Meaning / default | Sane value on 64 GB / RTX 3080 20 GB / 32 T |
|---|---|---|---|
| `title_memory_mb` (xcl.toml) | `config.rs:20-22`, `:116-123` | TitleMemoryStatus budget MiB; 0 = device standard (13 824 X / 8 192 S) | leave 0. #542: `11264` did **not** help (reached 1.6 GB free *sooner*) |
| `title_memory` (xcl.toml) | `config.rs:23-24`, `:83-91` | `auto` (MicrosoftGame.Config) / `standard` / `advanced`; `advanced` ⇒ `uma_mb` 4095 else 2048 (`:110-112`) | `auto` |
| `device_type` | `config.rs:11-12`, `:161` | `anaconda` (X) / `lockhart` (S) | `anaconda`. #542: `lockhart` stops the title at ~17 s (a 1920×1080 `R9G9B9E5_SHAREDEXP` RT+UAV is refused `E_INVALIDARG`); #248 comment 11 saw a black screen at 30 fps under `lockhart` |
| `uma_mb` | `config.rs:27-30`, `:110-112`; `XCL_UMA_MB` `uma.rs:733-737`, set from config in `host.rs:28-29` | unified memory MiB, up to 4 × 4095; 0 = 4095 (advanced) / 2048 | leave default (4 095 × 4 windows); don't raise blind — each coherent byte is commit |
| `XCL_COHERENT_MB` | `uma.rs:677-681` | size of the **committed** coherent window (clamped 64 KiB…4095 MiB); else learned size + 512 MB, and only if ≥ 17 GiB free commit (`:687-695`) | leave unset (we clear the 17 GiB gate). #156 comment 7 (RTX 3080 Ti): forcing 512 MB dropped the account prompt from **30.00 → 9.25 presents/s** — the coherent window is a *speed* knob too |
| `cache/uma_coherent.txt` | `uma.rs:673-675`, `:711-724` | the title's need from the last run; the learned value for GTA VI is ≈4.8 GB (capped to 4 095 MB) (#248 comment 8 "the coherent window was already learned (4.8 GB)") | delete it to reproduce "first run" behaviour; #632 (open) makes the first run take the whole window on Windows |
| `XCL_VRAM_ARENAS` | `vram.rs:647`, `:662` | forces the old arena path even when reserved resources are available (also used when tier-2 tiled resources are missing) | unset. #345: with it set on a 6 GB card the failure moved to `CreateHeap` for the 64 MB pools |
| `XCL_DXC_THREADS` | `dxc.rs:381-387` | DXC workers, default `logical − 1`, clamped 1…64 | 5950X → default **31**; free commit is not our limit, but #156 comment 8 measured "more creators than cores only lengthen each compile" → try **16** (physical cores) and compare |
| `XCL_PIPELINE_THREADS` | `shaders.rs:745-763` | offline `xcl shaders --precompile --pipelines` driver compiles at once, default 4: "each of the biggest takes ~1.5 GB in the driver – fifteen at once took 24 GB" | 4–8 (driver-bound, not commit-bound, for us) |
| `RESERVE_GB` (`set_memory_reserve`) | `dxc.rs:389-396` | 6 GB free commit kept for a running title; less for `--precompile`. **No env var in main** | n/a (we stay far above 6 GB) |
| `wait_for_memory` policy | `dxc.rs:410-433` | `6 GB + 1 GB × running` of free commit, else one-at-a-time, with a 60 s unconditional escape (the flaw #139 fixes) | unchanged; our measurements are the evidence |
| `wait_for_commit` | `real.rs:3321-3333` + `BIG_COMPILES { most: 1 }` `real.rs:3319` | background big compute PSOs: one at a time, **unbounded** wait for ≥ 3 GiB free commit | n/a for us; #567 (open) adds a 5 s grace |
| `XCL_LAZY_PSO` | `pso_async.rs:110-117` (default **on**) | pipelines get a stand-in at creation and are built at first use | leave on; `XCL_LAZY_PSO=0` to reproduce the old eager behaviour |
| `XCL_ASYNC_PSO` | `pso_async.rs:8`, `:68-69` (default on) | `=0` builds every pipeline inside the calling title call | leave on |
| `XCL_PSO_PRELOAD` | `pso_async.rs:227-241` (default **on**) | builds ahead of first use the pipelines an earlier run used (merged #690) | leave on — it is how a second run skips the multi-minute driver compiles |
| `XCL_PSO_DISK_CACHE` | `real.rs:3437-3455` (default **on**) | keep the driver's compiled blob of a compute program on disk under `<DXIL cache>\driver\` (merged #634) | leave on; `=0` to measure whether disk blobs change the 138 GB-style growth |
| `COMPUTE_BLOBS_MAX` | `real.rs:3540-3545` (constant, **no env var**) | in-memory driver blobs capped at **512 MiB** total, ≥ 16 KiB DXIL each | n/a — worth knowing when chasing M5: 512 MiB cannot explain 94 GB |
| `XCL_DXIL_CACHE` | `dxc.rs:554-556` | DXIL disk cache location (#345/#575 runs set e.g. `D:\gta6\dxil-test`) | point at the fast 1.3 TB volume; cold-cache runs are how the DXC-gate effects are measured |
| `XCL_DXC_DIR` | `dxc.rs:325`, `preflight.rs:91`, `README.md:95` | folder with `dxcompiler.dll` + `dxil.dll` | **DXC 1.9** from the DirectXShaderCompiler releases (1.7 is a `Note` in preflight: `dxc::RECOMMENDED`/`OUTDATED_COST`) |
| `XCL_D3D12_DIR` | `agility.rs:11-14`, `:30` | folder with the Agility SDK `D3D12Core.dll` (search order: env, next to exe, `.\D3D12\`, `%LOCALAPPDATA%\XCL\D3D12`) | **required on Windows 10**: Agility **1.620.2** in `%LOCALAPPDATA%\XCL\D3D12\` |
| `XCL_D3D12_DEBUG` | `real.rs:471`, `README.md:100` | D3D12 debug layer (needs Graphics Tools + `d3d12SDKLayers.dll`) | off for memory runs; it found the device-removal cause (`HANDOFF.md:1799-1804`) but "works with this title now" only after that fix |
| `XCL_ADAPTER` / `d3d12_adapter` | `gpu/adapter.rs:1,20,49`, `agility.rs:146`, `real.rs:453`, `runner.rs:89`, `README.md:153` | `auto` / `warp` / index / name substring | set `XCL_ADAPTER=nvidia` (or `3080`) so the iGPU/other adapter is never picked; PR #41 exists exactly for this |
| `XCL_RAYTRACING` | `config.rs:55,242-247` | force the reported raytracing tier (`off`/`tier1_0`/`tier1_1`) | leave `auto` (Ampere = tier 1.1, fine) |
| `XCL_NETWORK=0` | `netoff.rs:1,58-59,150-187`; `README`-adjacent `HANDOFF.md:1730-1731` | refuse the title's WinHTTP/Winsock **and the system's** for the whole process (loopback still allowed) | **always on for GTA VI**: its crash reporter uploads a 21.5–34 MB minidump to `submit.backtrace.io` on each crash (#156, #305, #505) |
| `XCL_ACTIVITY=1` | `host.rs:32-79` | every 2 s: activity line + `memory:` line = process commit MB, video memory local/non-local MB, target pages MB (pools MB), arenas in use/made MB, sparse pools MB (mapped MB) | **the single most useful knob for us**; #248's analysis was built on it |
| `XCL_RUN_SECONDS=n` | `host.rs:94-101` | end the title cleanly (fences signalled, queues drained, then `TerminateProcess`) | always use it; a process killed with GPU work in flight left the driver holding 12–16 GB (`HANDOFF.md:1626-1627`) |
| `XCL_TRACE_MEM[=n]` | `kernelx.rs:364-373` | the title's allocations ≥ 64 KiB (first n, default 60) + coherent-window allocations ≥ 1 MB with `#[track_caller]` | 200–1000 during bring-up |
| `XCL_THREAD_DUMP_AT=s1,s2…` | `host.rs:80-82`, `eh.rs:650` | unwind every thread at those seconds | use at 60/120/180/240 s — this is how #156/M4 was diagnosed |
| `XCL_TRACE_FAULTS=1` | `eh.rs:462-467` | log access violations as raised, before the title's handlers (first 32) | use it whenever the title dies at a bare `0xC0000005` (#298 comment 1 asks precisely this) |
| `XCL_FRAME_DUMP[=n]`, `XCL_FRAME_DUMP_FULL=1` | `present.rs:775-792`, `:929-930`; `README.md:135-141` | every n-th presented frame (default 120) written as `frame_<n>.bmp`, quarter size; also `d3d12.last_frame_dump` stats | 60–180 while loading |
| `XCL_DUMP_SHADERS=1`, `XCL_RECOMP_DXC=1` | `shader.rs:318-326`, `:379-383` | dump every submitted shader (+ disassembly/HLSL, optionally compile). Off by default because dumps "took 4.8 GB" (`HANDOFF.md:1758`) | off for memory runs |
| `XCL_LIST_TRACE=1`, `XCL_CONSOLE_LISTS=1`, `XCL_TRACE_FRAME=1`, `XCL_TRACE_ADDRESSES`, `XCL_DRED=1`, `XCL_WATCH*`, `XCL_PROBE[=rva]` | `title_list.rs:33-46`, `console_list.rs:12,50`, `bind.rs:434+`, `real.rs:483`, `eh.rs:743,900-911`, `device_x.rs:107` | slot-ring tracing, console-list capture, per-frame view census, DRED page-fault/breadcrumbs, hardware watchpoints/breakpoints on title code | `XCL_DRED=1` is opt-in and "twice the title stalled with it" (`HANDOFF.md:1636`) |
| `XCL_SKIP_CPU_CHECK=1` | `launcher.rs:358-387` | run even though the CPU lacks console-only instructions | not needed for us: the launcher checks AVX2/FMA/BMI1/BMI2/POPCNT/SSE4.2/LZCNT; Zen 3 has them; `clwb/clzero/rdpru/monitorx/mwaitx/rdpid` are emulated by `eh::emulate_console_only` (`HANDOFF.md:1817-1825`) |
| `XCL_DATA_ROOT` | `launcher.rs:9-12`, `main.rs:24-26` | title data root instead of `%LOCALAPPDATA%\XCL` (`xcl.toml`, `overlay\`, `saves\`, `pls\`, `temp\`, `cache\`, `logs\xcl.log`, `logs\report.json`) | set to the fast volume |
| `xcl.toml`: `graphics = "d3d12"/"null"`, `present = "auto"/"off"`, `aliases`, `stub_returns`, `mounts`, `pls_mb`, `console_type_raw`, `xbox_live_tokens`, `keyboard_mouse`, `mouse_sensitivity`, `window_width/height/pos`, `log_level`, `log_to_stderr` | `config.rs:25-74`, defaults `:160-190`, header text `:194-198` | per-title configuration; `graphics=null` = no rendering at all; `stub_returns` answers an auto-stub with a value | `graphics = "null"` is the knob for **isolating memory growth from GPU work** (see (d)) |
| `XCL_TEXTURE_SKIP_UNCHANGED=0` | `title_textures.rs:784-790` (default on, merged #486) | upload a texture whenever its pages were written, as before | leave on; #248 comment 13 measured a *different* crash with it off — worth one run each way |
| `XCL_SYNC_SMALL_TARGETS=0` | `title_textures.rs:339-347` | stop keeping small CPU-written render targets in step | leave on |
| `XCL_DSTORAGE_BCPACK_FILL=1` | `dstorage.rs:226-230` | fill a refused BCPack destination with solid blocks (request still fails) | useful to make streaming progress visible; it does **not** decode |
| `XCL_UMA_CHECK` (`real.rs:220-227,338-339`), `XCL_DEBUG_*` (`PS_SUB`, `PS_EXPR`, `MAGENTA`, `LOD0`, `NO_STENCIL`, `NO_CULL`), `XCL_PRESS_AT` / `XCL_PRESS_A_AT=s1,…`, `XCL_RUN_SECONDS`, `XCL_PIXEL`, `XCL_SPLIT_WAVE64`, `XCL_X64_ALL_MASKS`, `XCL_WAVE64_SPIN`, `XCL_RECOMP_WINDOWS`, `XCL_RECOMP_ONLY`, `XCL_RECOMP_WHY`, `XCL_RECOMP_NO_STRUCTURED`, `XCL_BLOB`, `XCL_SURVEY_*`, `XCL_EXAMPLE_HLSL`, `XCL_HLSL_OUT`, `XCL_GALLERY_DIR`, `XCL_DUMP_HLSL`, `XCL_DUMP_EVERY`, `XCL_CENSUS_*`, `XCL_TIME_*`, `XCL_FUZZ_ITERS`, `XCL_ISA_FULL`, `XCL_TRACE_APU`, `XCL_TRACE_UI_ANY`, `XCL_TRACE_MANY`, `XCL_TRACE_SHADERS`, `XCL_TRACE_FRAME_EVENTS`, `XCL_TRACE_IMPORTS`, `XCL_TRANSLATED_CACHE`, `XCL_DXC_ARGS`, `XCL_FORMS_NO_DXC`, `XCL_MS_EVERY`, `XCL_MS_SIGS`, `XCL_DUMP_GS`, `XCL_TEST_MEM_GB`, `XCL_SCATTER_PAGES`, `XCL_EARLY_PAGES`, `XCL_CONSOLE`, `XCL_KERNEL*`, `XCL_PRINT`, `XCL_ACTIVITY` | grep of `XCL_[A-Z0-9_]+` over the tree (see (c) above for the memory-relevant ones) | mostly diagnostics, test generators, and sample-data opt-ins; `XCL_SPLIT_WAVE64=1` forces the 32-lane split form on a wave64 GPU (used to validate NVIDIA code paths on AMD) | `XCL_SPLIT_WAVE64` is how the maintainers A/B NVIDIA behaviour on AMD (`HANDOFF.md:1694-1696,1724-1726`) |
| Sample-data opt-ins | `README.md:158-161`, `test.ps1:6`, `HANDOFF` §samples | `XCL_SAMPLE_RPF` (shader pack), `_DLLS`, `_TTPF`, `_BK2`, `_BVH4`, `_AWC`, `_XG`, `_DXC`, `_FSPX` | we own the retail package ⇒ we can set these; the repo deliberately ships no game data |

### Only in **open PRs** (documented here so we don't "invent" them)

| Knob | PR (state) | Meaning |
|---|---|---|
| `XCL_PAGE_BUDGET_MB` | #640 (open, draft) | opt-in budget for the 64 KiB title-texture page pools; at the cap, `evict_lru` unmaps the least-recently-touched **CPU-filled** textures (never GPU-owned targets, GPU-written (`pin`), < 4 tiles, or anything touched in 5 s) |
| `XCL_TARGET_PAGES_MB` | notdxbi's local experiment, #248 comment 12 | same idea applied to view-made targets; "Target pages still reached 5.2–5.6 GB with a budget of 3 GB or 1.5 GB" |
| `XCL_HEAP_WINDOWS=0` | #680 (open, draft; carried from closed #187) | memory windows addressed through `ResourceDescriptorHeap` instead of a per-access `switch` |
| `XCL_DRIVER_COMPILE_THREADS` (default **2** on 32-lane-only/NVIDIA, 4 on 64-lane), `XCL_BIG_PSO_KB` (default 256 KiB DXIL = "big"), `XCL_TRACE_PSO_TIME=1` | #214 (open, draft) | bound concurrent driver `Create*PipelineState`; title/`xcl-pso-urgent` threads exempt |
| `XCL_COMPUTE_PSO_WAIT_MS` (default 1500), `XCL_PSO_WAIT_MS=150` | Simon-CR's local branch (reported in #505 comment 10) and #533/#267 | cap how long a title thread waits for a pipeline before skipping |
| `XCL_SHORT_MOVIES=1` | #681 (open) | end a title's Bink videos after the first frame |
| `XCL_REQUIRE_GPU=wave64|mesh|wave64,mesh` | `README.md:156-157`, `test.ps1:14`, `runner.rs:426-439` | turn GPU skips into failures (CI hygiene) |
| `XCL_HOST` | `main.rs:48-50`, `launcher.rs:439-459` | launcher→host handoff (internal) |

---

## (d) What our machine changes, and what to try first

**What changes**

1. **Commit limit stops being the wall.** Set a fixed page file (e.g. initial 64 GB / max 128 GB) on
   a fast volume: the limit becomes ~128–190 GB. That removes M1 (headroom 0.44–0.98 GiB in #333),
   keeps the 17 GiB coherent gate open (`uma.rs:699`), keeps `wait_for_memory`'s 6 GB floor
   permanently satisfied (`dxc.rs:410-433`), and keeps `wait_for_commit`'s 3 GiB floor satisfied
   (`real.rs:3328`) so #567's deadlock cannot fire. We become the reference machine for
   "same code path, 100+ GB of headroom".
2. **20 GB of VRAM clears the M6 arithmetic.** The published failure is 7 445 MB of sparse tiles +
   ~4 GB of coherent-side video charges on a 5 966 MiB card (#345). A 12 GB card already produced
   "zero `CreatePlacedResourceX 0x8007000E`, zero `sparse windows: no video memory`" through the
   whole loading phase (#345 comment 1). The published stalls at 13.7–14.4 GB local (#640, #505
   comments) say our extra headroom buys ~60–90 s of streaming, not immunity: M7's texture/target
   growth is unbounded until it is bounded by a PR.
3. **We will still hit the NVIDIA time wall.** Ampere-specific numbers (#156 comment 9, RTX 3070,
   driver 610.88): `CreateComputePipelineState` = 10.5 s at 298 KB DXIL, 31 s at 613 KB, 55 s at
   863 KB, >2 min at ~1.1 MB, one creator; "the Ampere driver itself is slow on large programs,
   whatever the DXC"; DXC 1.9 only helps above 1 MB of HLSL where XCL switches to `-O1`. 4 memory
   windows cost 3.1× driver time (#156 comment 15) — that's why #680's heap windows (9–10×) matter
   for us. Also: `gpu_clamp_and_omod_per_instruction` is known to fail on NVIDIA driver **591.86**
   only; "**the reports here on 610.88, 617.42 and 621.24 pass the whole suite**" (#42 comment 69) —
   our driver is explicitly green for the test suite.
4. **Windows 10 is supported but needs the Agility SDK.** Direct evidence in main:
   `README.md:96-101`, `agility.rs:3-17,273` (needs Win10 22H2 KB5029331+ for
   `ID3D12SDKConfiguration1`), and `preflight.rs:68` gives the fix line "on Windows 10, put the
   D3D12 Agility SDK's `D3D12Core.dll` in a `D3D12` folder next to xcl.exe".
   Reports on 19045:
   * #42 comment 7 — Win10 Pro `10.0.19045.5794`: inbox D3D12 caps at SM 6.5, **all SM 6.6+ GPU
     tests skip**; with Agility **1.620.2** (`D3D12SDKVersion = 620`, #75) 378 passed / 0 failed /
     **0 GPU skips** on the 9800X3D iGPU and 349+2 on an RTX 5070.
   * #42 comment 69 — Win10 Pro **22H2 19045.6466** + RTX 4090 + Agility 1.620.2 in
     `%LOCALAPPDATA%\XCL\D3D12\`: "**no test was skipped for SM 6.6**", 680 passed / 0 failed.
   * #42 comments 62/64 — Win10 Pro 19045 + RX 7700 XT: 676–677 passed but **86 GPU skips
     (84 "no GPU")**: `gpu_scalar_relative_moves` reports no SM 6.6 and with the Agility package it
     logs `ID3D12SDKConfiguration1 unavailable … 0x80004002` and "falls back to inbox D3D12".
     ⇒ contradictory reports: the same OS build works with Agility for one contributor and not for
     another. **Treat Win10+Agility as "verify locally before trusting it"**, and if the fallback
     line appears, that is a real Windows-10 blocker to report (a title drawing nothing at SM 6.5 is
     the preflight `Error`: `preflight.rs:67-69`).
   * Other Win10 runs: #156 comment 8 (`i7-7700K, 16 GB, RTX 5080, Windows 10 22H2 (19045)` —
     driver timings + a title run), #572 (Win10 Home 19045, 32 GB, RTX 3090), #641 (Win10 build
     19045, 7800X3D + RTX 3090, Agility 1.620.2, 691/1/41), #567 (Win10 IoT Enterprise LTSC 2024
     **26300** with an RTX 3080 — note: that is the Win11-era build, not 19045), #333 comment 3
     (author writes "Windows 10 25H2 26200.9711").
5. **wave32/NVIDIA is a first-class path in main, with known residual inexactness.**
   `README.md:110-115` + `docs/wave64-on-wave32.md` (design, hazards, cost); merged #94 (lane-local
   mask handling: mask-only loops 1.64–1.68× → 1.04–1.11× on an RTX 3090) and #133 (wave64 VS/PS
   lanes 32–63 via `upper_lanes.rs`: `wave_hazards` **0 programs** left in the pack). Still open per
   `HANDOFF.md:1720-1723`: "whole-wave code in a partial wave reads lanes the PC never launched …
   325 of the 436 reduction programs have a min reduction" — i.e. **some pixels differ on every GPU,
   not just ours**. RTX 3080 test-suite status: 352–354 passed / 0 failed with 39–41 wave64 GPU
   tests skipping as passes (#42 body + comments 1, 8); 2 `XCL_SAMPLE_RPF` mesh tests fail on a
   3080 because wave64 MS on wave32 was unimplemented then (#41 body item 4, issue #39).
6. **20 GB VRAM specifically: no published report.** Every GTA VI report I found is 6/8/10/12/16/24 GB
   (and one 16 GB AMD + 64 GB RAM, #505 comment 10; one 12 GB + 64 GB RAM, #640's author; one 16 GB +
   64 GB RAM, #156 comment 6; one 24 GB RTX 4090 + 31.6 GB, #232). **Unverified** whether anyone has
   run XCL on a 20 GB card. Our combination (Win10 19045 + 3080 20 GB + 64 GB + 32 threads + 610.88)
   appears to be new ⇒ the deliverable value of our runs is the *curves*, not the conclusion.

**What to try first, in order**

1. Build current `main` (`cargo build --release --workspace`), install Agility **1.620.2** into
   `%LOCALAPPDATA%\XCL\D3D12\`, DXC 1.9 via `XCL_DXC_DIR`, then `xcl run H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK`
   with `XCL_NETWORK=0 XCL_ACTIVITY=1 XCL_RUN_SECONDS=240 XCL_ADAPTER=nvidia XCL_DATA_ROOT=…`,
   `XCL_DXC_THREADS` **left unset** first (that is what #572 asks testers to do).
   Run once with an **empty** `XCL_DATA_ROOT` (first run → 512 MB coherent window) and once after
   the learned size (4 095 MB) — the 4.8 GB-vs-512 MB difference is worth ~12 fps → 30 fps at the
   prompt (#632's measurements, and #156 comment 7's 9.25 → 30.00 presents/s).
2. `scripts/smoke.ps1 -Game …` twice (60 s and 180 s) and paste the `xcl-smoke v1` blocks —
   note #156 comment 13's warning: **60 s runs do not reach steady state** on this title
   (340 vs 271 frames, ±25 %); 180 s settles.
3. Capture the `memory:` line every 2 s for a 300–450 s run (menus → world loading). Deliverable:
   the curve of `committed` / `local video memory` / `target pages (pools)` / `arenas` /
   `sparse pools (mapped)` against time on a machine with ≥ 100 GB of commit headroom. Nobody has
   that curve (all published curves stop at 32/45/55/61/70 GB limits).
4. Reproduce #542's claim under our conditions: `XCL_DXC_THREADS=4` vs unset. Their data says the
   growth is thread-count-independent (39.48 vs 39.89 GB) and that #602/#451/#435 (all merged) moved
   the peak to ~28.3 GB; we can confirm on current `main` without a stack of open PRs.
5. Isolate title memory from GPU work with `graphics = "null"` (`config.rs:44-45`) — **unverified
   whether the GTA VI title survives a null-device run**; if it does, the residual commit growth is
   attributable to XCL's CPU-side structures alone, which is exactly what #505 comment 24 and #194
   are missing.
6. Because we are far from the commit wall, precompile the pack:
   `xcl shaders <shaders.rpf> --precompile --only cs` (fills both caches outside the title;
   `HANDOFF.md:1759-1762`) and `--pipelines` (`XCL_PIPELINE_THREADS=4`) so the driver's disk cache
   is warm; then the title's world loading stops being dominated by DXC. Budget: one contributor
   measured ~35 min of CPU for the full pack at 65.5 s per 842 programs on 15 threads
   (#156 comment 14); our 31 threads should roughly halve that.

---

## (e) Candidate patches we could own (file + function), with the open PR that already covers it

Duplicates are the main risk here: the repo has ≥ 300 open PRs and the maintainer explicitly
closed several "because main already had them in another form" (#198 comment 4). Check the open
list and the per-contributor trackers (`Kalmarv/xcl/issues/1`, `JGonzalezRodriguez/xcl/issues/1`,
`WebIdentity1/xcl/issues/1`, …) from #198 before starting.

| Candidate patch (main @ `main`) | Covered by (state) | What we can add |
|---|---|---|
| `crates/xcl/src/hle/kernelx/lazy.rs::lazy::commit` — remove the page from `LAZY` only after `MEM_COMMIT` succeeds; record failure count + last page + `GetLastError()` in atomics; name `1455 ERROR_COMMITMENT_LIMIT` in the crash line (`eh.rs`) | **#487** (`bf21bcb`, open), **#488** (`bd7b9e4`, open; flaky test on 2 machines), **#502** (`be9423c`, open; logs from inside the vectored handler) for issue **#467**. Two reviewers converge on "#487's approach + #488's error names, test rewritten as allocator injection (#502's `commit_with`)". Also folded in Simon-CR's local variant (#505 comment 4: commit *before* removing from `LAZY`) | Do **not** open a 4th PR. Offer the missing evidence instead: a **real** commit-limit failure under a title. Cheap: run with a small fixed page file (e.g. 8 GB) to *force* 1455 and show the new crash line vs a bare `0xC0000005`; then re-run with the 128 GB page file and show the same scene with no commit failure — that pair isolates the fix from OOM noise, which is exactly what #467's author says is missing ("Not a fix for running out of commit (#333/#194/#345), only an honest failure") |
| `crates/xcl/src/gpu/recomp/dxc.rs::wait_for_memory` / `may_start` — reserve only the running compiles' *growth* (300 MB), CAS the running count, one escape per minute, condition-variable wakeups | **#139** (open, 5 comments; **does not merge onto `main`**: conflicts with `RESERVE_GB`/`set_memory_reserve` added by `956a476`; needs a rebase using `RESERVE_GB` as `COMPILE_FLOOR`); **#572** (open, memory-bounded *default thread count*, no retail smoke blocks yet); #113 already merged | Our box can measure the case none of them have: with ≥ 100 GB free commit the gate is inert, so a **paired run** (main vs #139-rebased, `XCL_DXC_THREADS` unset, empty `XCL_DXIL_CACHE`) should show identical wall time and identical DXIL digests ⇒ proves the gate costs nothing when commit is plentiful, and the 2× win only matters at 6–12 GB free commit. Also #139's accounting gap ("growth went roughly with HLSL size: 160 MB at 1 MB, 460 MB at 1.9 MB, 1.5 GB at 3.8 MB") is testable here cheaply with `--precompile` and a private-commit sampler |
| `crates/xcl/src/hle/d3d12x/real.rs::wait_for_commit` — bounded wait / no deadlock while holding `BIG_COMPILES {most: 1}` | **#567** (open, 5 s `BIG_COMMIT_GRACE`); **#214** (open, 30 s cap + `XCL_DRIVER_COMPILE_THREADS` + exempt title/urgent threads); Simon-CR's local "reclaim + a 30 s deadline to `BIG_COMPILES::wait_for_commit()`" (#505 comment 10) | Ours is the machine where the condition never fires. Add the *negative* result + a forced reproduction by shrinking the page file (they explicitly list "16 GB or fixed-pagefile Windows machines where `pagefile.sys` cannot grow" as **Not tested**) |
| Cap concurrent **driver** compiles at ~8 and prefer fewer workers than logical CPUs for the driver lane; log when the gate blocks | #214 (open) proposes the gate; #156 comment 15 (QemmHD) measured the curve and proposes `min(logical/2, 8)` + a `SetProcessInformation(ProcessPowerThrottling)` call; #156 comment 8 (imnicho) independently proposes workers ≤ physical cores; **no PR** carries the `ProcessPowerThrottling` one-liner (hybrid Intel only) | The `xcl-pso` lane cap is the one thing our 32 threads make *more* relevant, not less (we start ~31 DXC + up to 15 `xcl-pso` workers). Test `XCL_DRIVER_COMPILE_THREADS=2/4/8` from #214's branch on our card and publish `CreateComputePipelineState` timings + peak private bytes: nobody has published an **Ampere** multi-creator curve (the existing ones are RTX 4070S/5070Ti/5080/3090) |
| `crates/xcl/src/hle/d3d12x/vram.rs::Pages` (`take_tile`) — a budget that returns tiles for **CPU-filled title textures** (and view-made targets) LRU | **#640** (open, `XCL_PAGE_BUDGET_MB`, author's own 12 GB card; "Not tested: AMD and Intel GPUs; cards with less video memory"), **#782** (open: the budget must see textures in use by their T# in the view heaps), **#292** (open, different approach: retire overwritten placements + cap `MADE` at 65 536), **#490/#496/#532/#483/#522/#551** (open lifecycle work), notdxbi's `XCL_TARGET_PAGES_MB` experiment (#248 comment 12, no PR) | With 20 GB we can run #640 **off/on** at the default (no budget) for as long as it takes to saturate, and publish the `target pages (pools)` + `local video memory` curves that decide whether eviction is needed at 20 GB at all. Notdxbi's numbers say a per-pool budget is *not* enough ("Target pages still reached 5.2–5.6 GB with a budget of 3 GB or 1.5 GB") — our data point is the cheapest way to confirm/refute that |
| `crates/xcl/src/hle/d3d12x/real.rs::resource_at` / `static MADE` (`real.rs:2070-2072`) — the by-address view cache keeps one resource per `(va, desc)` for the life of the process | **#292** (open) replaces it with `ResourceAtCache` (retire + 2 s cooling + `MADE_MAX` 65 536). #484 (merged) and #751 (open, "title texture reads outside the coherent window use the safe copy") touch neighbours | Instrument before patching: count `MADE` entries and their held pages against `XCL_ACTIVITY`'s `target pages`. That number is the missing half of #248 comment 12's analysis and of #640's "62 k live targets" |
| `crates/xcl/src/hle/d3d12x/real.rs::keep_compute_blob` / `COMPUTE_BLOBS` (`real.rs:3540-3545`, 512 MiB cap) and the driver's **live pipeline objects** (M5: 17 GB → 111 GB over 1 067 pipelines) | #634 + #636 (**merged**, disk + in-memory blobs), **#690** (merged, preload), #214/#567 (gates). **No issue or PR attributes the growth of kept-alive PSOs themselves** | The most promising thing for us to own: with ≥ 128 GB of commit we can build 2 000+ big compute pipelines in one process and watch private bytes with `XCL_PSO_DISK_CACHE=0` vs default, and with `XCL_PSO_PRELOAD=0`, to split "driver live objects" from "in-progress compiles" from "XCL's own copies" (#505 comment 24's exact open question). File that as a measurement issue against #505 / #194 |
| Observability: a `memory:` line at every crash, at error exit, and whenever commit grows by 1 GiB, plus the title's request breakdown (`memstat.rs`) | **#194** (open PR, `gbuyssens`; not merged — `report.rs` has no memory field) | This is the cleanest "small, wanted, un-duplicated" job: **rebase #194 onto current `main` and re-run the suite + the title**. Two contributors explicitly say they need it ("13–24 GiB of the system's commit did not belong to the process at the time of the dump. I could not attribute it, which is why the memory line of #194 would help here" — #333 comment 4) |
| `crates/xcl/src/gpu/recomp/{emit.rs,mod.rs,pso.rs}` — memory windows via the descriptor heap (kill the per-access `switch`) | **#680** (open draft, carried from closed #187), docs-only **#346** (open). The **NVIDIA regression** it must answer: with heap windows 5 retail PS/CS build on `main` but fail `0x8007000E` on an RTX 5070 Ti + driver 616.92 (#156 comment 3), and its fallback (re-translate in the switch form) is commit-free at 41 GB; on the other hand on RTX 4090/621.24 + DXC 1.8.2502 "the driver's compiler ends the process" during the first large compute batch | Ampere is exactly the missing data point for #680's "Open point" (unknown whether driver, card or DXC decides). Running our 3080/610.88 with `XCL_HEAP_WINDOWS` on/off through world loading is high-value and cheap |
| `crates/xcl/src/hle/dstorage.rs` — a BCPack decoder (main **refuses** BC1/BC3/BC4/BC5/BC6H/BC7 with `0x89240030`) | #208 (open, "BCPack entropy stage for all modes, not yet called"), #505 comments 9/10 report working local ports (VIctory-derived `bcpack.rs` + tables; a pure-Rust 8-mode/285-config BC7 + BC3/4/5 module), #760 (open tests for BC1 into scattered physical pages), #225-adjacent | Note: BCPack is a *streaming* blocker rather than an OOM one — "The crash stays the same, so BCPack is not the cause of it, but the title needs BCPack to stream the world" (#505 body). If we want a non-duplicated contribution, **measure refusals per mode from `report.json → dstorage` on a full 1.0.2.1 package** and post the counts |

**Patches already merged that we should simply verify on our machine** (so the maintainers see an
Ampere/Win10 line in the column): #602 (detile/hash in place), #451 (reused upload memory), #435
(layout tables one period), #486 (skip unchanged uploads), #490 (idle-page sweep), #484, #634/#636
(driver blobs), #690 (preload), #347/#348/#443 (write-watch and sparse-lock fixes), #225 (exact-size
arenas), #244 (lazy commit race), #300 (timer resolution), #306/#435/#490 + the
`CopyFromSubresource` fix referenced as #684.

---

## (f) URLs used

Repository content (GitHub REST `contents` with `Accept: application/vnd.github.raw+json`, and the
whole tree via the tarball `https://codeload.github.com/ivall/xcl/tar.gz/refs/heads/main`):

* `https://api.github.com/repos/ivall/xcl`
* `https://api.github.com/repos/ivall/xcl/git/trees/main?recursive=1`
* `https://api.github.com/repos/ivall/xcl/commits?per_page=60`
* `https://api.github.com/repos/ivall/xcl/pulls?state=open&per_page=100&page=1|2|3&sort=created&direction=desc`
* `https://api.github.com/rate_limit`
* Files read: `https://api.github.com/repos/ivall/xcl/contents/{path}` for
  `README.md`, `HANDOFF.md`, `AGENTS.md`, `CONTRIBUTING.md`, `SECURITY.md`, `THIRD_PARTY.md`,
  `Cargo.toml`, `crates/xcl/Cargo.toml`, `crates/xcl/data/stubdb.toml`,
  `docs/specs/2026-11-20-xcl-design.md`, `docs/wave64-on-wave32.md`,
  `crates/xcl/src/config.rs`, `main.rs`, `host.rs`, `launcher.rs`, `manifest.rs`, `preflight.rs`,
  `report.rs`, `log.rs`, `util.rs`, `crates/xcl/src/gpu/adapter.rs`, `gpu/uma.rs`,
  `gpu/recomp/dxc.rs`, `crates/xcl/src/hle/kernelx/lazy.rs`, `hle/d3d12x/vram.rs`,
  `hle/d3d12x/sparse.rs`, `hle/d3d12x/title_list.rs`, `scripts/smoke.ps1`
  (fetched as raw; also present in the tarball, which was the copy used for `gpu/agility.rs`,
  `hle/d3d12x/real.rs`, `hle/d3d12x/pso_async.rs`, `hle/d3d12x/title_textures.rs`,
  `hle/dstorage.rs`, `hle/netoff.rs`, `shaders.rs`, `gpu/shader.rs`, `eh.rs`, `hle/kernelx.rs`,
  `gpu/tiling.rs`)
* Issues / PRs (`/issues/{n}` and `/issues/{n}/comments?per_page=100`, plus
  `/issues/248/timeline?per_page=100`): **#41, #42, #113, #139, #156, #194, #198, #214, #225,
  #232, #244, #248, #292, #298, #333, #345, #435, #451, #467, #505, #542, #567, #572, #602, #632,
  #634, #640, #680, #575**
  (pages: `https://github.com/ivall/xcl/issues/{n}` and `https://github.com/ivall/xcl/pull/{n}`)
* `https://github.com/ivall/xcl/issues/42` — fetched once with `web_fetch` (HTML; title only,
  body came from the API).

Issues/PRs **named inside** the material above but not independently fetched (state quoted from the
referring text only, treat as unverified): #19, #34, #36, #39, #40, #44, #45, #74, #75, #104, #106,
#107, #148–#151 refs in HANDOFF, #159, #162, #172, #173, #174, #175, #183, #186, #187, #195, #196,
#197, #199, #202, #203, #206, #208, #211, #215, #235, #236, #252, #256, #257, #258, #266, #267,
#269, #273, #278, #281, #283, #284, #294, #301, #302, #304, #305, #306, #314, #320, #321, #335,
#340, #346, #347, #348, #351, #440, #443, #445, #447, #452, #454, #455, #458, #461, #463, #468,
#470, #472, #473, #480, #483, #484, #486, #488, #489, #490, #494, #495, #496, #499, #501, #502,
#503, #504, #507, #508, #510, #512, #516, #522, #523, #531, #532, #533, #534, #539, #545?, #551,
#555, #556, #560, #561, #573, #574, #576, #588, #592, #594, #603, #610, #614, #617, #625, #626,
#629, #631, #636, #637, #641, #642, #647, #673, #681, #682, #684, #690, #708, #712, #713, #733,
#734, #751, #760, #762, #764, #765, #768, #770, #771, #778, #782, #783, #789.
Also referenced: external projects `github.com/boykopovar/AnyPS5`,
`github.com/WinDurango/WinDurango`, `github.com/microsoft/DirectXShaderCompiler/releases`,
`github.com/microsoft/libHttpClient` (GDK thunk + XAsync contract), `HansKristian-Work/dxil-spirv#372`
(a GPU hang on Ada through vkd3d-proton, cited in #198 comment 3), and the contributor work
trackers `github.com/Kalmarv/xcl/issues/1`, `…/JGonzalezRodriguez/xcl/issues/1`,
`…/BlestTerror/xcl/issues/1`, `…/AlpPesen/xcl/issues/1`, `…/WebIdentity1/xcl/issues/1`
(all from #198; not opened). Discord: `https://discord.gg/Tb4UbPUzRH` (`README.md:3-4`), moved to
`discord.gg/xcl` by #771 (merged).

Fetch-mechanics notes for the next pass: `raw.githubusercontent.com` still fails here; the
**tarball is the cheap path** for file reads (it does not consume the 60/hour unauthenticated API
budget), and the unauthenticated API budget is shared with other agents on this IP — two batches
got rate-limited mid-run.
