# 0012 - XCL memory model: where the bytes actually go

**Date:** 2026-11-24. Read-only inspection of `ivall/xcl` at `main` as cloned on
2026-11-24 (no build, no run in this document; the measurements it refers to are in
[0009](0009-xcl-run-here-and-memory-patches.md)). Every claim cites a file and line in
`crates/xcl/src/`. Written to answer one question: which of XCL`s memory costs are
configurable, which are duplicated on purpose, and which are never given back.

# XCL memory model — why `game_scarlett_master.exe` eats host RAM + VRAM

Repo `H:\leonida\xcl` (read-only inspection; no build, no run). All paths relative to `crates/xcl/src/`.
Two mechanisms dominate: **sparse windows** (title memory mirrored in VRAM tiles) and the
**adaptive coherent window** (committed host RAM the GPU reads in place). Both are two-sided by design.

## 1. Budget table — every pool XCL creates

| # | pool | what it is | how the size is chosen | where the bytes live | evidence |
|---|------|-----------|------------------------|---------------------|----------|
| 1 | sparse windows 0..2 | 3×4 GiB of write-watched **reserved** address space standing for the console's unified memory | fixed: `(MAX_WINDOWS-1)*WINDOW` = 12 GiB VA, never configurable | **reservation only** (no commit until the title commits) | `gpu/uma.rs:169-180`, `:28-29`, `:208-226` |
| 2 | the title's committed pages inside them | the CPU view of the title's own graphics memory / 64 KiB physical pages | the title's own `VirtualAlloc`/`XMemAlloc` calls; no cap | **host RAM + system commit** (`VirtualAlloc MEM_COMMIT`) | `hle/kernelx.rs:227-233`, `:242-256`; `hle/d3d12x/sparse.rs:1129-1138` |
| 3 | sparse VRAM tile pools | D3D12 DEFAULT heaps of 1024×64 KiB = **64 MiB each**, one tile per 64 KiB tile the title committed | demand-driven, grows until `CreateHeap` fails; whole pool released when all its tiles are free (≥2 s after the fence) | **VRAM** (WDDM also charges commit for it) | `hle/d3d12x/sparse.rs:35-36`, `:571-599`, `:604-625` |
| 4 | coherent window (window 3) | committed, write-watched region opened as a D3D12 heap with `OpenExistingHeapFromAddress`, so GPU reads it where it is | `coherent_hint()`: `XCL_COHERENT_MB`, else last run's `cache/uma_coherent.txt` + 512 MiB, capped 4095 MiB; floor `RUNTIME_COMMITTED_CAP` 512 MiB | **host RAM + commit** (the D3D12 heap is an import, not extra VRAM) | `gpu/uma.rs:26`, `:34`, `:169-182`, `:678-696`; `hle/d3d12x/real.rs:298-337` |
| 5 | XCL's per-draw arena pool | `POOL` = 64 MiB carved off the end of the committed window, handed out in `ARENA_BLOCK` = 256 KiB blocks | constant, capped at a quarter of the committed window | host RAM (inside #4) | `gpu/uma.rs:57-58`, `:125-153`, `:636`; log `bind.rs:59-64` "82 blocks held for 82 allocators" |
| 6 | descriptor-heap range of window 0 | `DESC_HEADROOM` = 512 MiB of sparse window 0 kept for 32-bit-addressable heaps | constant; never the title's | VA + host RAM + VRAM tiles (it is a sparse alloc) | `gpu/uma.rs:31-32`, `:228-241`; `hle/d3d12x/console_heap.rs:236-273` |
| 7 | `vram::Pages` | one 64 KiB **video-memory page per 64 KiB page of title address** a GPU-owned target (RT/DS/UAV) covers; 64 MiB DEFAULT pool heaps | demand-driven; a page is kept 2 s after its last user, a freed tile cools 2 s | **VRAM only** ("the CPU never sees these textures") | `hle/d3d12x/vram.rs:160-168`, `:284-307`, `:360-391`, `:11`; log `:263` |
| 8 | `vram` arenas | fallback: one DEFAULT heap per placement range (64 KiB, 4 MiB for MSAA); kept 2 s after last user | demand-driven, `GetResourceAllocationInfo` size | **VRAM** | `hle/d3d12x/vram.rs:68-85`, `:136-157`, `:667-682`; log `:154` = your `31457280 bytes of arenas made so far` (one 30 MiB arena) |
| 9 | title-texture PC copies | sampled textures placed at title addresses: a PC resource kept in step with the CPU bytes | per-texture; XG size, PC size if XG has no model | **VRAM** (reserved on #7 when possible, else committed DEFAULT) | `hle/d3d12x/device_x.rs:888-911`; `hle/d3d12x/title_textures.rs:1-16`, `:44-70` |
| 10 | upload/readback staging | 64 MiB UPLOAD ring + 1 MiB zero buffer + 16 MiB READBACK + 16 upload allocators/lists | constants, created lazily, never shrunk | **host RAM** (UPLOAD/READBACK heaps) + VRAM copy traffic | `hle/d3d12x/sparse.rs:38`, `:42`, `:44`, `:46`, `:824-899` |
| 11 | write-watch bookkeeping | per mapped tile: `TileEntry` with 16 per-4 KiB-page hash arrays, 64×u64 = 512 B each | one entry per mapped 64 KiB tile; hash box allocated only on first write | host RAM, ≤8 KiB per 64 KiB tile (~12.5 %) + 128 B of pointers | `hle/d3d12x/sparse.rs:85-97`, `:50-51`, tests `:1555-1577` |
| 12 | graphics reservations that found no room | write-watched plain `VirtualAlloc` for GPU-visible title memory | the title's size, no cap | host RAM when committed; also walked by the write-watch scan | `hle/kernelx.rs:294-299`, `:328-335`, `:351-358` |
| 13 | title memory *budget* (a number, not bytes) | what `TitleMemoryStatus`/`XMemGetWorkingSetStatistics` report | `title_memory_mb` else 13 824 MiB (Series X) / 8 192 (Series S) | none — reported against `PrivateUsage` | `config.rs:20-22`, `:117-123`; `hle/kernelx.rs:683-687`, `:748-766`, `:733-746` |
| 14 | PLS quota 2048 MB | disk quota (`S:\` → `{data}\pls`) | manifest `<PLS>` else 4096 | disk, not RAM | `config.rs:25-26`, `:95-103`, `:130-136` |

Measured `coherent 83/512 MB` is #4 handed-out bytes (`gpu/uma.rs:606-609` + `:421-429`);
`sparse 7431 MB` is #1 **reserved address space**, not RAM/VRAM (`gpu/uma.rs:370-373` sums
`sparse_free.1`, filled by `:106`). The 20091/20480 MiB VRAM is #3 + #7 + #8 + #9 (+ backbuffers);
the ~6 GB private / 2937 MiB free physical is #2 + #4 + #10 + #11 + #12.

## 2. The sparse window is two-sided by construction

Yes — a 64 KiB "video memory" tile also occupies host RAM, plus tracking, plus a transient copy:

- the tile exists because the title *committed* CPU pages: `commit_sparse` →
  `mem::VirtualAlloc(a, n, MEM_COMMIT, …)` then `sparse::committed(q, n)` (`hle/kernelx.rs:227-233`);
  `sparse::alloc` does the same (`hle/d3d12x/sparse.rs:1129-1138`).
- `sparse::committed` → `ensure_mapped` → `take_tile` → `CreateHeap(…D3D12_HEAP_TYPE_DEFAULT…)`:
  "sparse windows: no video memory for more tiles" (`sparse.rs:571-599`, `:717-756`).
  Your `12731 tiles mapped` ≈ 796 MiB of VRAM sitting on top of ~796 MiB of committed host RAM.
- module header states it: "On the GPU each sparse window is a reserved (tiled) buffer of 4 GiB whose
  64 KiB tiles are mapped onto video-memory heaps as the title commits pages. The CPU's view stays
  the title's memory: what the CPU wrote (write-watch) is copied into the tiles before the title's
  next ExecuteCommandLists via an asynchronous ring-buffered staging upload queue" (`sparse.rs:8-12`).
- the copy is a third buffer: `std::ptr::copy_nonoverlapping(cur, p.add(dst_off), chunk)` into the
  64 MiB UPLOAD ring, then `CopyBufferRegion(window, …, staging, dst_off, chunk)` (`sparse.rs:1113-1115`,
  `:824-845`) — your `1286 MB of CPU writes uploaded`.
- dirty-page tracking cost: `GetWriteWatch(WRITE_WATCH_FLAG_RESET, …)` per watched range
  (`hle/d3d12x/title_textures.rs:670-684`, `:686-711`) into a reusable 16 384-entry page list
  (`:611-614`, `:701-703`) = your `72195 dirty pages`; then a 64-byte hash per page decides what goes
  (`sparse.rs:1352-1401`, `changed_chunks`/`scan_page`).
- a *sampled* texture at a sparse address pays three times: the committed CPU page (#2), the sparse
  VRAM tile (#3, because the title committed there) **and** the PC texture on `vram::Pages`
  (`device_x.rs:899` + `:911`), with an upload on every CPU write.

## 3. `XCL_VRAM_ARENAS`, `XCL_UMA_MB`/`uma_mb`, `title_memory`, `title_memory_mb`

- `XCL_VRAM_ARENAS` (any value = on): `vram::place_pages` returns `None` (`vram.rs:647`) so sampled
  textures get a committed PC resource (`device_x.rs:905`), and `place` skips the tiled pages and goes
  straight to arenas (`vram.rs:662-673`). **Raises VRAM** (arena = whole placement range, 4 MiB aligned
  for MSAA), does not shrink host RAM. History: "15 GB of arenas in 2 s … the device was removed"
  (`vram.rs:14-24`; `HANDOFF.md:1791-1793`); your log shows only 30 MiB of arenas made, so the tiled
  path is already doing its job — do **not** set this on a 20 GB card.
- `uma_mb` (`config.rs:27-30`) → `host.rs:28-29` `XCL_UMA_MB` → `gpu/uma.rs:737` (env default 2048).
  In the runtime layout it is nearly inert: `for_runtime_with` computes
  `committed = size.min(coherent.max(512 MiB))` with `size = (mb<<20).max(coherent)` (`uma.rs:170`,
  `:739`). With `cache/uma_coherent.txt` = 4 770 168 832 B (4549 MiB) the coherent window is
  `min(4095, 4095)` = **4095 MiB of committed host RAM whether `uma_mb` is 2048 or 4095**. Sparse
  window count is fixed at 3 regardless (`uma.rs:171`).
- `title_memory = "auto"|"advanced"|"standard"` (`config.rs:23-24`, `:84-91`, manifest
  `<XboxAnacondaTitleMemory>` `manifest.rs:12-14`, `:53-54`): only picks `uma_mb` = 4095 vs 2048
  (`config.rs:110-112`) — see the caveat above, so switching to `"standard"` alone will not shrink RAM here.
- `title_memory_mb` (`config.rs:20-22`, `:117-123`): the **reported** budget only
  (`kernelx.rs:683`, `:753`). It shrinks neither pool directly, but the engine sizes its own pools and
  texture streaming from it (`kernelx.rs:672-674`), so **lowering it reduces both host RAM and VRAM at
  the source** — the most effective lever you have.

## 4. The adaptive coherent window ("up to N MB from the next run")

- Accumulator: every committed allocation with a `PAGE_GRAPHICS_*` protection adds `size` to
  `ASKED` and calls `note_coherent_need(asked)` (`hle/kernelx.rs:301-309`, page-graphics protection
  constant at `:360-362`).
- `note_coherent_need` writes the running total to `coherent_file()` =
  `state::data_dir()/cache/uma_coherent.txt` and logs your exact line with
  `(bytes + RUNTIME_COMMITTED_CAP).min(MAX_SIZE)` (`gpu/uma.rs:711-724`, `:673-675`, `:34`, `:26`):
  4549 + 512 → 4095 MB cap. The file is **monotonic** — written only when `bytes > before` (`:716`).
- Confirmed on disk: `H:\leonida\xcl-data\RockstarGamesInc.28872443D20A7\cache\uma_coherent.txt`
  contains `4770168832` (= 4549 MiB), so the next run opens with a 4095 MiB coherent window.
- Next run reads it in `coherent_hint()` (`uma.rs:677-696`), gated: if free commit < `NEEDS_FOR_COHERENT_HEAPS`
  = **17 GiB** the hint is ignored and the window stays 512 MiB (`uma.rs:687-699`).
- Pin it: `XCL_COHERENT_MB=<MiB>` wins over the file (`uma.rs:679-681`); delete the file for 512 MiB;
  `XCL_COHERENT_HEAPS=0` turns the whole path off (`kernelx.rs:306`) so those heaps fall back to
  plain write-watched memory (#12) — then console buffers outside unified memory get empty V#s
  (`real.rs:1750-1751`, `HANDOFF.md:1751`).
- Inside the window, headroom is rationed: `KEEP` 96 MiB for `VirtualAlloc` heaps
  (`kernelx.rs:313-319`), `COHERENT_KEPT` 128 MiB before committed console textures stop taking it
  (`real.rs:1204-1245`), `COHERENT_FLOOR` 16 MiB for readback (`real.rs:1248-1264`), readback ≤64 MiB /
  CUSTOM-WB ≤16 MiB else it spills to sparse VRAM (`real.rs:1250-1252`, `:1278-1287`).

## 5. Never-released / silently-retried candidates for "out of memory"

- **`vram::Pages` pool heaps are never given back.** `take_tile` only ever `self.pools.push(heap?)`
  (`vram.rs:303`); tiles return to `free`/`cooling` (`vram.rs:280-282`, `:360-391`) but the 64 MiB
  DEFAULT heaps stay for the process. Contrast sparse, which retires empty pools
  (`sparse.rs:601-625`). Peak VRAM for GPU-owned targets is therefore sticky.
- 2 s retention ×3: arena `IDLE` (`vram.rs:60-63`, `:165`), page `IDLE` + tile `COOL`
  (`vram.rs:163-168`), sparse `retired` pools (`sparse.rs:212-214`, `:604-625`).
- Placed buffers pin sparse pool tiles so decommit cannot free them: `pinned.entry(tile) += 1`
  (`sparse.rs:1468-1470`), checked at `sparse.rs:180`; freed only by `forget_buffer` (`:1477-1490`).
- The whole UMA region is a `OnceLock` for the process; `Drop` only frees the `VirtualAlloc`s if it
  is ever dropped, which it is not (`uma.rs:667`, `:612-620`, `:734-756`).
- Silent retries / fallbacks (each hides a real shortage):
  - lazy page commit failure keeps the page lazy and retries on the next access, counted but not
    reported until the crash line: `kernelx/lazy.rs:33-57`, `:59-71` (issues **#333, #467** named there).
  - `place_on_pages` failure → arena → committed resource of its own: `vram.rs:506-513`, `vram.rs:299-301`
    ("no video memory for more pages"), `device_x.rs:902-907`.
  - `CreatePlacedResource` in the coherent heap fails → "keeping a separate resource (the shader will
    not see it)": `real.rs:1360-1366`.
  - sparse full → coherent full → plain memory: `kernelx.rs:267-275`, `:282-299`, `:310-320`;
    physical-page homes fall back the same way (`kernelx.rs:1064-1072`).
  - `coherent_hint` silently refuses the large window under 17 GiB free commit (`uma.rs:687-693`).
  - DXC compiles stall (up to 60 s) instead of failing under commit pressure:
    `gpu/recomp/dxc.rs:442-465`, `RESERVE_GB` 6 (`:421-423`).
  - UMA import check failure = GPU reads zeros/stale data with no allocation error: `real.rs:284-290`,
    `:219-227` (issue **#175** named at `real.rs:226`) — plausible cause of your "shaders cannot run"
    combined state; verify with `XCL_UMA_CHECK` output in the log.
- Issue numbers literally in the code I read: #344 `sparse.rs:550`; #175 `real.rs:226`; #333/#467
  `kernelx/lazy.rs:36,161`; #106 `config.rs:83,222`; #283/#248 `title_textures.rs:1349,1634`.
  (#225 / #99 / #122 / PR #40 appear in `HANDOFF.md` only, e.g. `:1834`, `:883`, `:952`, `:1423`.)
- Unclear, not invented: the game's own `TileHeap: used (174Mb) - total (6236Mb)` does not map to any
  XCL counter I found (`pool_bytes`/`page_bytes`/`arena_bytes`, `host.rs:59-75`); it is most likely the
  title's own view of its reservation, not XCL's.

## 6. Experiments for a 64 GB / 20 GB machine

| change | proves / relieves |
|---|---|
| `XCL_COHERENT_MB=512` (or delete `…\cache\uma_coherent.txt`) | whether the 4095 MiB coherent window is the commit/RAM hog; relieves ~3.5 GB commit **and** the per-submit write-watch scan over it (`uma.rs:679-681`; `HANDOFF.md:1835`) |
| `XCL_COHERENT_MB=1024` / `2048` | the knee: how much title GPU-heap memory the game needs inside unified memory before the picture breaks (`kernelx.rs:310-320`) |
| `XCL_COHERENT_HEAPS=0` | what still works when the title's GPU heaps live in plain write-watched RAM; expect empty V#s for console buffers outside UMA (`real.rs:1750-1751`) |
| `title_memory_mb = 6144` (or 8192) in `xcl.toml` | that the *engine* is the allocator: its streaming pools shrink to the reported budget (`config.rs:117-123`, `kernelx.rs:753`) — the only knob that lowers host RAM **and** VRAM |
| `title_memory = "standard"` + `uma_mb = 2048` + `XCL_COHERENT_MB=512` together | that `uma_mb`/`title_memory` alone do nothing while the cache file demands 4095 MiB (`uma.rs:170`) |
| `XCL_VRAM_ARENAS=1` (short run, watch the log) | how much the tiled `Pages` path is saving: arenas should jump VRAM to the 3.5 GB-of-addresses scale and risk `0x887A0001` (`vram.rs:14-24`, `:647`, `:662`) |
| `XCL_ACTIVITY=1` | the per-2 s split: commit, local/non-local VRAM, target pages+pools, arenas, sparse pools+mapped — tells you which side is climbing (`host.rs:32-75`) |
| `XCL_TRACE_MEM=1` | who fills the coherent window: the title's ≥64 KiB allocations and each ≥1 MiB / failed coherent allocation with the XCL source line (`kernelx.rs:364-379`, `uma.rs:521-535`) |
| `XCL_UMA_CHECK=0` | whether the coherent-window import check is what costs time / reports "shaders cannot run" (`real.rs:338-347`) |
| `graphics = "null"` in `xcl.toml` | separates UMA/title-memory growth (#1 #2 #4 #12) from all D3D12 costs (#3 #7 #8 #9) with the same title start-up (`config.rs:44-45`) |
| raise the page file so free commit > 17 GiB | the gate at `uma.rs:699` is commit-based, not RAM-based: on a 64 GB box with a small page file the coherent window is silently refused |
