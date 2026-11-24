# Reproduction commands

Everything below was run on one machine (Windows 10 19045, RTX 3080 20 GB) with
**no administrator rights** and no installed Visual Studio / Windows SDK, which
is why the C++ runtime is used as the project's own CI artifact instead of a
local build.

Placeholders used here:

```
LEONIDA   = H:\leonida\Leonida-continued            # repo checkout
PKG       = H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK    # our game copy
WORK      = H:\leonida\work\shaders                 # scratch (tens of GB)
PY        = python 3.12.14
```

## 0. Toolchain (user-installed, no admin)

```
PY                     = Python 3.12.14
LLVM_MC                = <llvm 23.1.6>\Library\bin\llvm-mc.exe
PATH                  += <spirv-tools 2026.4>\Library\bin     # spirv-as, spirv-val
LEONIDA_W64_EMULATE    = 1                                    # 32-wide subgroups
```

`llvm-mc` must support `-triple=amdgcn--amdpal -mcpu=gfx1013`; LLVM 23.1.6 from
a conda environment does. SPIRV-Tools is needed by `rdna2spirv.py` for
`spirv-val` even with `--no-asm`.

## 1. Check the package

```
%PY% make_game.py --check --game %PKG% --work H:\leonida\work_check --out H:\leonida\out
```

Before the fix: reported as an unsupported version (only the three probe files
are named). After restoring the 40 absent files:

```
check: Xbox Series package 1.0.2.1, 108 files
check: all files present. Executable found.
```

## 2. Verify a copy against the repo manifest, and repair it

```
%PY% scripts\verify_and_copy.py            # report only
%PY% scripts\verify_and_copy.py --copy     # install the verified files
```

Each candidate is accepted only when its size **and** SHA-256 match
`game/xbox-1.0.2.1.json`; the installed copy is hashed again in place.
`scripts\pkg_diff.py` additionally compares the copy against the release
torrent's own file list (bdecoded from the `.torrent`, not committed here).

## 3. Shader stage

```
%PY% tools\shader_carve.py  %PKG%\shaders.rpf %WORK%\dxbc
%PY% tools\fssm_unpack.py   %WORK%\dxbc
%PY% tools\shader_disasm.py %WORK%\dxbc --out %WORK%\disasm --jobs 16
```

Translation runs as 16 parallel shards, then the index parts are merged (see
`scripts\shard.cmd` for one shard):

```
%PY% tools\rdna2spirv.py %WORK%\dxbc\disasm --out %WORK%\spirv --shard <i>/16 --no-asm --wave64-emulate
%PY% tools\rdna2spirv.py %WORK%\dxbc\disasm --out %WORK%\spirv --merge --no-asm --wave64-emulate
```

## 4. Create every pipeline on the GPU

```
vk_pipeline_check.exe %WORK%\spirv H:\leonida\out\pipeline_cache.bin --jobs 16 --stats H:\leonida\logs\pipeline_stats_full.txt
```

The slice we used to calibrate the cost used `--jobs 8` and a 1,500-module
subset. Statistics lines are `stage,kind,value`; the per-shard translation
summaries are parsed by `scripts\collect_results.py`, which writes
`data\results_summary.json`.

## 5. Runtime

```
gta6rt.exe --dry-run --game-dir %PKG% --overlay <overlay dir> --trace-d3d12
gta6rt.exe --init    --game-dir %PKG% --overlay <overlay dir>
gta6rt.exe --run     --game-dir %PKG% --overlay <overlay dir>
```

with `LEONIDA_GAME_DIR=%PKG%`, `LEONIDA_D3D12=vulkan` and
`LEONIDA_SHADERS=%WORK%\spirv`. `gta6rt.exe`, `gta6rt_tls_host.dll` and
`vk_pipeline_check.exe` come from the `runtime-windows` CI artifact of the
commit being tested — recorded per run in `data\results_summary.json`.
