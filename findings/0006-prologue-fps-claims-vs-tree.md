finding: "the prologue runs at 0.2-2 FPS" is ahead of what this tree can do, and
the "diagnostics + DRED" build it was measured with is not a build of this repo.

Context: a widely shared report (2026-11-24, Chinese community) says the first
entry into the prologue compiles a large number of shaders and pipelines, that a
cold cache stutters badly, that many world shaders are still unsupported
(`v_swap_b32`, 64-bit image atomics, untracked lane masks, unknown stride
buffers) so those draws/dispatches are dropped, and that even with a release
build and a hot cache the prologue stays around **0.2-2 FPS**. It opens with
"this run used diagnostics + DRED, slower than release". Read next to the
repository, three parts of that do not line up.

## 1. DRED does not exist in this runtime

- Nothing under `runtime/` mentions DRED. `docs/d3d12_vulkan.md:2143` lists
  "DRED, protected sessions, meta commands, shared handles | stubs | Not needed
  for single-player boot; return a clean failure and log.", and `:3969` lists
  "DRED tooling" among what is not done.
- The D3D12 debug layer is never enabled either: the PC path calls the host
  `D3D12CreateDevice` directly (`runtime/shims/d3d12_xs.cpp:189-194`) and there
  is no `ID3D12Debug::EnableDebugLayer` anywhere in `runtime/shims`. The Vulkan
  path builds its own device (`d3d12_xs.cpp:165-186`).
- The opt-in diagnostics that *do* exist are `--trace FILE`
  (`runtime/shims/startup_trace.h:1-4`, flushed per event), `--trace-d3d12`
  (a mutex plus `fprintf`/`fflush` per recorded call, `d3d12_trace.h:22-29` -
  the real slowdown), `LEONIDA_VK_VALIDATION=1` (Khronos validation layer +
  synchronization validation, `d3d12_vulkan_device.cpp:9324-9357`), and
  `LEONIDA_SKIP_INT3=1`. There is no `--no-diagnostics` / `--no-dred` switch,
  because all of them are off by default.

So a "diagnostics + DRED" number cannot be compared against a run of `main`, and
the release path here is simply "pass no diagnostic flags at all".

## 2. The documented furthest point is before the first draw

- `README.md:49-54`: "**Early. The game does not boot yet.**", and the row
  "Booting, story mode, anything playable | No".
- `docs/retail_boot_chain.md` is the furthest documented attempt: 13 stops, each
  "the first failure with every fix above it in place", measured 2026-11-23 at
  `1cc6e3c1` **with PRs #6709, #4531, #6582, #4313, #4348 and #2490 merged
  locally**, on Windows 11 + RTX 4090. Its own conclusion at `:101-104`:
  "These are one run's first failures, not a list of what is missing. Every
  stand-in above is local ... **Nothing has reached a draw or a present yet.**"
- `docs/retail_boot_intel_host.md:20-24, 39-42` goes further - past stops 27/28,
  and one run "went past every documented stop and ran the title's frame loop
  until the 900 s timeout: 100,457 D3D12 calls" - but on an **unmerged 31-PR
  stack**, and `:59-62` states "nothing drawn: every pipeline was a stub ... No
  translated shaders were loaded in these runs".
- `LEONIDA_STUB_PIPELINES`, which that run depends on, is **not in this clone's
  code** at all (it appears only in `docs/retail_boot_intel_host.md:22,39`).

An artifact built from plain `main` therefore should not be expected to show a
frame rate in the prologue; the expected outcome is one of the documented stops.

## 3. Two of the four "unsupported shader feature" names are wrong, one way each

Checked at `ff8ce388`:

- `v_swap_b32` is **implemented**: `tools/rdna2spirv.py:8896-8903`, with the
  both-operands-written semantics tracked by the mask analyses (`:16633`,
  `:16665`, `:16926`, `tools/lane_masks.py:177`) and covered by
  `tests/semantic/test_alu_bitwise_swap.py` and a GPU fixture
  (`runtime/test/shaders/ps_ops3.asm:13`). It is not a reason to drop a draw.
- "64-bit image atomic" is a documented *fidelity* gap, not a rejection:
  `docs/design.md:424` says the two-VGPR `dmask:0x3` forms still operate on the
  low 32-bit dword, and `tools/rdna2spirv.py:14246-14270` deliberately keeps the
  low-dword behaviour "so corpus translation count does not drop" while
  `Int64ImageEXT` support is handled separately. The upper half is silently
  wrong; the shader still translates and still draws.
- "Untracked lane mask" **is** a rejection: `rdna2spirv.py:7568/7571/8334`
  `raise Unsupported(...)` for `s_quadmask_b32/b64`,
  `s_bitreplicate_b64_b32`, `s_flbit_i32_b64/i64`; and `:19056-19059` deletes
  the stale `.spv` and drops the entry from `index.json`
  (`drop_stale`, `:19038-19043`).
- "Unknown stride buffer" is not a string in this repository. The nearest real
  refusal is `runtime/shims/d3d12_vulkan_device.cpp:6628-6635` ("a bad stride"),
  which logs once and leaves the descriptor slot unwritten.

## 4. What "the draw gets dropped" actually does - worse than dropped

A missing module makes PSO creation fail with a logged reason
(`d3d12_vulkan_device.cpp:3539-3542` for graphics, `:3998-4007` for compute,
`E_INVALIDARG`), the pipeline id stays 0, `record_draw`/`record_dispatch` set
`invalid_` (`d3d12_com.cpp:1392-1417`), the command is never appended
(`runtime/src/command_list.h:738-756`), **and `Close()` returns `E_INVALIDARG`
for the whole list** (`d3d12_com.cpp:217-223`). So it is not "one draw missing
from an otherwise fine frame": the entire command list is refused at
`ExecuteCommandLists`. Only two cases are genuinely silent (no/empty viewport,
`d3d12_com.cpp:1415-1417`; zero counts, `command_list.h:741,749,754`).

Suggest: when quoting a frame rate from this project, say which commit and which
locally merged PR set produced it - the difference between "stop 13, nothing
drawn" and "frame loop running with stub pipelines" is the whole story, and the
tracker that used to hold that context is gone.

Needs: no game data. Verified at `ff8ce388`; the runtime facts quoted are from
`runtime/shims/` and `docs/` at that commit.
