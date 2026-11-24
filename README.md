# GTA VI / Leonida on one real PC — field notes

Independent measurements of [Leonida](https://github.com/ubiquitarianism/leonida)
(the Xbox Series → PC static recompiler for *Grand Theft Auto VI*) on a single
Windows 10 machine with our own copy of the 1.0.2.1 package.

**No game data here.** Only file names, byte counts and SHA-256 values that
already appear in the project's own `game/xbox-1.0.2.1.json`, plus numbers from
our own logs.

> Provenance note: these measurements were originally reported against
> `ItsNotRexed/Leonida`, which returned **404 on 2026-11-24** (its issue tracker
> and our posted comments went with it). The same commit history lives on at
> `ubiquitarianism/leonida` ("Leonida Continued", GPL-3.0); our old HEAD
> `e0816d6af` is an ancestor of its `main`. This repository is the durable copy
> of what we measured.

## TL;DR

1. **An incomplete copy of the game is reported as "unsupported", not "incomplete".**
   Our package held 68 of the 108 manifest entries, every present one matching
   its manifest size exactly (0 size mismatches), and 40 entries absent —
   33,390,534 bytes in total, including all three version-probe files and the
   16 DLLs the runtime maps. `make_game.py --check` rejected it as
   *"This doesn't look like a supported version of the game"*, naming only the
   three probes, so a reader cannot tell "wrong game" from "download stopped
   early".
   Restoring those 40 files from the package's own torrent — each verified
   against the repo manifest by size **and** SHA-256 — makes the check pass:

   ```
   08:38:00  check: Xbox Series package 1.0.2.1, 108 files
   08:38:00  check: all files present. Executable found.
   ```

2. **The whole shader stage reproduces on this machine**, with no AMD hardware:
   26,503 shaders carved → 26,503 FSSM blobs (`problems: {}`) → 26,503
   disassembled clean → **26,503 translated, 26,503 pass `spirv-val`**.

3. **wave64 on a 32-wide subgroup** (NVIDIA, `--wave64-emulate`):
   tier A 5,059 / tier B 101 / **tier C 8,245** — tier C graphics shaders are
   not exact on 32-wide subgroups, which is the largest single correctness risk
   on every NVIDIA and Intel card.

4. **Full-corpus Vulkan pipeline creation on a 20 GB RTX 3080** — see
   [`data/results_summary.json`](data/results_summary.json). The 1,500-module
   calibration slice: 1,500/1,500 pipelines created, 0 failed, 0 skipped,
   600 s wall on 8 threads, cache 262,215,635 bytes; PS mean 4.505 s
   (slowest 45.64 s), MS mean 1.614 s (slowest 41.34 s).

5. **Driver behaviour we hit, and what fixed it:** `vk_pipeline_check` logged
   `periodic pipeline cache save ... failed: vkGetPipelineCacheData returned
   VK_INCOMPLETE` on driver 610.88 at `--jobs 16` with a ~2.7 GB cache — all
   four snapshot attempts failed, so that periodic save was lost. Current main
   already carries the fix (`8d34751d`, PR #9722: read with growing slack), our
   artifact build `4eb6155d` does not. Details in
   [`findings/0002`](findings/0002-pipeline-cache-vk-incomplete.md).

6. **`Win32_VideoController.AdapterRAM` caps at 4 GiB.** This card reports
   4,293,918,720 bytes (`0xFFF00000`, 4 GiB − 1 MiB) through WMI but 20,480 MiB
   through Vulkan and `nvidia-smi`. A spec checker that trusts WMI
   under-reports every >4 GB card.

## Machine

| | |
| --- | --- |
| OS | Windows 10 Pro for Workstations 19045 x64 |
| CPU | AMD Ryzen 9 5950X, 16C/32T |
| RAM | 64 GB |
| GPU | NVIDIA GeForce RTX 3080 **20 GB**, driver 610.88 |
| Vulkan | 1.4.341, subgroup 32–32, mesh shader + barycentric + maintenance8 present |
| Python | 3.12.14 |
| LLVM | 23.1.6 (`llvm-mc -triple=amdgcn--amdpal -mcpu=gfx1013`) |
| SPIRV-Tools | 2026.4 (`spirv-as`, `spirv-val`) |
| CMake / ninja | 3.28.0-rc5 / 1.13.2 |

`pc_checker.py --cli` on this machine: "Looks good" for both profiles, and
"Leonida compatibility and FPS: unknown (The game doesn't boot yet)."

## How to reproduce

The exact commands we ran, in order, are in [`REPRO.md`](REPRO.md). The scripts
are in [`scripts/`](scripts) (their path constants are this machine's defaults).

## Findings

| # | Finding | Where |
| --- | --- | --- |
| 1 | An incomplete copy is reported as "unsupported"; the per-file report is never reached because the 3 probes fail first | `make_game.py` `PROBES` / `probe_mismatches()` / `load_version()`; `find_dumps()` also skips a folder without `MicrosoftGame.Config`, so `--find` lists nothing |
| 2 | with 16 jobs and a ~2.7 GB cache all four pipeline-cache snapshot attempts return `VK_INCOMPLETE`, so a periodic save is lost (already fixed upstream by PR #9722) | `runtime/test/pipeline_cache_snapshot.h`, `vk_pipeline_check.cpp:935/943` at `4eb6155d` |
| 3 | WMI `AdapterRAM` is capped at 4 GiB; a 20 GB card reads as `0xFFF00000` | `pc_checker.py` GPU sizing (PR #5112 was open when the repo went 404) |
| 4 | wave64 graphics tier C = 8,245 of 26,503 modules is approximate on 32-wide subgroups | `tools/rdna2spirv.py`, `wave64_graphics_reasons` in the index |

Suggested fix for #1: when no version matches but at least half the manifest
entries match by name and size, print `N of M manifest files present with
matching sizes` plus the missing names and say the copy looks **incomplete**.
The diagnostic is pure Python and testable with synthetic manifests.

## Status of the boot attempt

The runtime is used here as the project's own CI artifact
(`runtime-windows`), because this machine has no C++ toolchain that can be
installed without administrator rights. The corpus pipeline cache built by
`vk_pipeline_check` is the warm cache that avoids the first-entry compile
stutter reported for the prologue.

## License

Our notes, scripts and numbers: CC0-1.0 (see [`LICENSE`](LICENSE)).
Leonida itself is GPL-3.0; the game data is not redistributable and is not here.
