# 0014 — What our Win10 runs prove, and exactly what a Win10 build of XCL has to change

**Date:** 2026-11-24 · **Repo:** `ivall/xcl` `main` @ `64b3f35` (+ our two memory patches) ·
**Host:** Windows 10 19045.3324, RTX 3080 20 GB, driver 610.88, 64 GB RAM, commit limit 156 GB,
DXC 1.9.2609.5, Agility 1.620.2 present but unloadable. Sampled with `port/run_xcl_long.ps1`
(10 s samples of VRAM, commit charge, XCL's own accounting line), with `XCL_FRAME_DUMP` so
"did it display something" is a measurement and not a screenshot rumour.

## The game launches, presents, and shows nothing — measured three times

| run | exe | lifetime | presents | frame dump | verdict |
|---|---|---|---|---|---|
| 12:37 | upstream `main` build | 37 s | ~130 | — | crash `exe+0xb5a5f8 read at 0x68` |
| 17:22 | #488 head | 28 s | `d3d12.presents = 132`, `frame_boundaries = 132` | `frame=127, 3840x2160, format 28, sampled_pixels=518400, **non_dark_samples=0**` | black screen |
| 18:41 | ours + `XCL_ALLOW_SM65=1` | 22 s | `presents = 78` | `frame=71, sampled_pixels=518400, **non_dark_samples=0**` | black screen |

So the title runs far enough to open the D3D12.X device, build 3840x2160 display targets,
issue `PresentX` ~130 times and stream via DirectStorage (4 944 requests, 262 MB, **0 failed**)
— and every sampled pixel of every dumped frame is dark, because
`d3d12.translated_pipelines = 0` and `shaders.recomp_programs = 0`.

## Memory is not what stops us on this machine

The 16:2x reading (20091/20480 MiB VRAM, 2937 MiB free RAM) was taken while another GPU program
was running. With that program closed, the same run reads:

```
t=11s  vram 3018/20480 MiB   private 6312 MiB   free phys 42838 MiB   commit 44929/156648 MiB
t=22s  vram 1446            (process gone)      free phys 52919 MiB   commit 28021 MiB
```

XCL's own accounting during the run: `coherent 3998/4095 MB, sparse 7444 MB, 40 blocks held for
40 allocators`. Note `sparse 7444 MB` is **address space**, not committed bytes (0012). Nothing
here is near the commit limit, so #333/#542-style exhaustion and our lazy-commit patch are not
the reason the run ends. It ends at `game_scarlett_master.exe+0xb5a5f8` (read at `0x68`), inside
`Game Init`, with the frame counter still at 0 in the title's own crash context.

## Why `XCL_ALLOW_SM65=1` changed nothing — the gate is upstream of the gate

We relaxed the device check in `gpu/recomp/runner.rs` (accept SM 6.5 when
`XCL_ALLOW_SM65=1`, and log it). The warning never appeared in the log, and
`Gpu` in that file is only constructed by that one constructor — so **the recompiler was never
built at all**. The decision is made earlier: `preflight.rs:133` probes
`6_6/6_5/6_0`, and `preflight.rs:68` raises an **Error**-level
`"no SM 6.6 … shaders cannot run"` for `g.shader_model < 6.6`, which is what the run summary
still prints verbatim. A Win10 build therefore has to clear preflight first, then the runner.

## The next wall, already visible without touching the emitter

The run's `d3d12.translation_errors` reads:

```
XCL ABI root signature: 参数错误。 (0x80070057)
XCL ABI root signature with static samplers: 参数错误。 (0x80070057)
mesh pipeline with its MS d7c434f73b4b811c in the AS slot — refused
```

`0x80070057` = `E_INVALIDARG` from the **root signature** that XCL's shader ABI is built around
(`pso::abi_root_signature`, described at `runner.rs:125-129`: heaps "directly indexed
(SM 6.6 `ResourceDescriptorHeap`)"). The Windows 10 inbox D3D12 runtime refuses that layout —
which is the same fact 0013 measured from the other side: **62.5 % of sampled programs index
`ResourceDescriptorHeap`, 43.7 % `SamplerDescriptorHeap`, 51.6 % carry `[WaveSize(n)]`, and DXC
only declares/permits those at Shader Model 6.6.**

## The change list for a Win10-first build, in the order it has to be done

| # | where | what | evidence it is needed |
|---|---|---|---|
| 1 | `preflight.rs:68`, `:133` | make the SM 6.6 check a warning when 6.5 is present | the warning never fired while `runner.rs` was patched: preflight decides first |
| 2 | `gpu/recomp/runner.rs:101-106` | accept 6.5 behind `XCL_ALLOW_SM65` | done in our tree |
| 3 | `pso::abi_root_signature` (via `runner.rs:127`) | replace heap-indexing with descriptor tables/bound arrays | `E_INVALIDARG` in every run's `translation_errors` |
| 4 | `emit.rs:2169, 2273, 2296, 2324, 2353, 2364, 2387`, `:1553` | emit declared array indexing instead of `ResourceDescriptorHeap`/`SamplerDescriptorHeap` | 0013: 302/483 and 211/483 blocked at 6.5 |
| 5 | `emit.rs:4139, 4238, 4291, 4326, 4388` | drop `[WaveSize(n)]`; XCL already has the wave32 path (`pso.rs:540 XCL_SPLIT_WAVE64`) | 0013: 249/483 blocked at 6.5 |
| 6 | `pso.rs:460, 476-478, 512, 514, 592`, `runner.rs:597, 608` | target strings to `{cs,vs,ps,gs,ms}_6_5` | 0013: 12.8 % pass at 6.5 today, 100 % after rewriting 4+5 |
| 7 | DXIL validation | ship DXC 1.9's `dxil.dll` next to `xcl.exe` (we have it) | DXIL 1.7+ is not validatable by the inbox `dxil.dll` |

Nothing on this list is a flag: 3-6 are a real change to the shader ABI and emitter. What is
encouraging, and measured, is that the emitter output is *mechanically* portable — 483/483
sampled programs compile at 6.6, and the same 483 compile at 6.5 once RDH/SRH and `[WaveSize]`
are rewritten (0013 §4).

## Do this together with upstream's newest work, not against it

The watch note (`../upstream/2026-11-24-xcl-watch.md`) shows 24 commits and 10 merged PRs today,
including the translated-shader cache (#762) and D3D12.X lifetime work (#866/#897/#907), and —
most relevant to staying in the game — PR **#891**'s `XCL_PSO_WAIT_MS`, which on a Shader-Model-6.6
machine makes the world render and keeps the process alive to 240 s, after #505 identified the
"GPU Loc Sig" watchdog as threads waiting unbounded for compute pipeline builds. A Win10 build
should rebase onto that and keep the same bound, otherwise we fix the shaders and then hit the
watchdog the same way.
