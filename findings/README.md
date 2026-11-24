# Findings

Each file is one report, written in the form we would have posted upstream
(`finding:` first line, then `Where / Why it matters / Suggest / Needs / Measured`).
The upstream tracker where these were first reported was deleted on 2026-11-24,
so they are kept here.

| file | finding |
| --- | --- |
| [`0001-incomplete-copy.md`](0001-incomplete-copy.md) | an incomplete 1.0.2.1 copy is reported only as "This doesn't look like a supported version of the game", never as a partial match |
| [`0002-pipeline-cache-vk-incomplete.md`](0002-pipeline-cache-vk-incomplete.md) | the periodic pipeline-cache save fails with `VK_INCOMPLETE` on NVIDIA driver 610.88 |
| [`0003-wmi-adapter-ram.md`](0003-wmi-adapter-ram.md) | `Win32_VideoController.AdapterRAM` caps at 4 GiB, so a 20 GB card reads as 4 GB |
| [`0004-retail-dry-run-11-unimplemented.md`](0004-retail-dry-run-11-unimplemented.md) | a `--dry-run` over the executable that **is** in our package maps all five modules with 11 unimplemented imports (audio + DirectStorage only), and an artifact one day older refuses to map anything |
| [`0005-isolate-docs-drift.md`](0005-isolate-docs-drift.md) | `docs/pipeline_check.md` still calls crash isolation POSIX-only although the same PR gave it a Windows child-process path |
| [`0006-prologue-fps-claims-vs-tree.md`](0006-prologue-fps-claims-vs-tree.md) | the circulating "0.2-2 FPS in the prologue, measured with diagnostics + DRED" report cannot come from this tree, and two of its four "unsupported shader" names are wrong |
| [`0007-run-stops-at-xmem-attributes.md`](0007-run-stops-at-xmem-attributes.md) | `--run` reaches the entry point and halts at the console memory-attribute wall: an assert, and one instruction past it a null dereference; the GPU is never touched, so no shader has rendered yet — **superseded by [0011](0011-the-boot-stop-is-gameinputcreate.md)** |
| [`0008-mingw-port-runs-the-runtime.md`](0008-mingw-port-runs-the-runtime.md) | the runtime builds and behaves identically under MinGW-w64 (no Visual Studio): 662 MSVC-only CMake switches, `__uuidof`, SEH, `-mconsole -municode` for `wmain`, and three real source bugs the port surfaced |
| [`0009-xcl-run-here-and-memory-patches.md`](0009-xcl-run-here-and-memory-patches.md) | XCL runs our package end to end; why Shader Model 6.6 is unreachable on 19045.3324 (measured, not inferred), and two memory patches (upstream #467, #542) built and unit-tested here |
| [`0010-xcl-approach-and-oom.md`](0010-xcl-approach-and-oom.md) | a reading of XCL's design and of the twelve separate memory-exhaustion mechanisms behind its "runs out of memory" reports, with what a 64 GB / 20 GB machine changes |
| [`0011-the-boot-stop-is-gameinputcreate.md`](0011-the-boot-stop-is-gameinputcreate.md) | the guest's `call; test eax,eax; js -> int3` is on `GameInput.dll!ordinal 1` (`GameInputCreate`): the SDL3 GameInput shim was not built, so the host's GameInput.dll answered FAILED, and the null read is the unwritten out-parameter |
| [`0012-xcl-memory-model.md`](0012-xcl-memory-model.md) | pool by pool, where XCL's memory actually goes: sparse pages cost host RAM *and* a VRAM tile each, `sparse 7431 MB` is address space not bytes, a learned `cache/uma_coherent.txt` overrides `uma_mb`, and `vram::Pages` pool heaps are never returned |
| [`0013-sm65-target-feasibility.md`](0013-sm65-target-feasibility.md) | XCL's own HLSL compiled by standalone DXC: 483/483 at Shader Model 6.6, only 62/483 at 6.5 — `ResourceDescriptorHeap` (62.5 %) and `[WaveSize]` (51.6 %) are the hard reasons, and 483/483 pass at 6.5 once those two are rewritten |
| [`0014-win10-port-what-the-runs-prove.md`](0014-win10-port-what-the-runs-prove.md) | three measured runs: the title presents 132 frames and every sampled pixel is dark (`non_dark_samples = 0`), memory is nowhere near the limit, `XCL_ALLOW_SM65` never fires because `preflight.rs` decides first, and the next wall is the SM 6.6 ABI root signature (`E_INVALIDARG`) — with the seven-step change list for a Win10 build |

## A note on the artifacts in `../port`

Everything here is our own writing or our own code, with one exception: `../port/xcl-mem-patches.diff` is a diff of [ivall/xcl](https://github.com/ivall/xcl), which is **GPL-2.0-only**; it is published as a patch against their tree, not as code we license. The generated `../port/mingw_uuidof_d3d.h` is a table of interface GUIDs extracted by us from the Microsoft Direct3D 12 headers. No game data is published here: the names and byte counts come from the package manifest, as upstream's own `check_no_game_data.py` allows.
