# 0008 — Building the Leonida runtime with MinGW-w64 (no Visual Studio), and what it proves

**Date:** 2026-11-24 · **Tree:** `ubiquitarianism/leonida` @ `ff8ce388` (the successor of the
404'd `ItsNotRexed/Leonida`) · **Host:** Windows 10 Pro for Workstations 19045, Ryzen 9 5950X
(16C/32T), 64 GB RAM, RTX 3080 20 GB, driver 610.88, Vulkan 1.4.341

The repo only ever builds the runtime with MSVC (`scripts/build_runtime.ps1`, CI on the
`windows-latest` runner). This machine has no Visual Studio and no Windows SDK, so
`gta6rt.exe` had to be built with something else to iterate on shim code at all.
**It now builds and runs with MinGW-w64 (conda-forge GCC 16.2.0 / binutils 2.46.1).**

## Result: the MinGW build is behaviourally identical to the CI artifact

| mode | CI artifact `ff8ce388` | our MinGW build |
|---|---|---|
| `--dry-run` | `game_scarlett_master.exe … shim=93 host=421 module=72 unimplemented=1`, `UNIMPLEMENTED XCRDAPI.dll!DStorageGetFactory`, 5 modules mapped, exit 0 | same, byte-identical report |
| `--init --trace` | 15 records: 4 `dllmain result:1`, 2 TLS callbacks `exe+0x55dd4f4`/`+0x55e2ebc` reason 1, `exit code:0`, the two callbacks again reason 0 | same 15 records, same addresses |
| `--run --trace` | 18 records, last = `exception 0x80000003 at exe+0x5925915`, 13-frame stack | same 18 records, same stack |
| `--run --trace` + `LEONIDA_SKIP_INT3=1` | 19 records: `int3_skipped exe+0x5925915`, then `0xc0000005 read of 0x0 at exe+0x5925903` | same 19 records, same stack |

So the port is not a second, degraded runtime: whatever the MSVC build can and cannot do, it
can and cannot do. That makes this compiler loop usable for shim work — an edit to one
`shims/*.cpp` recompiles and relinks in about a minute (`ninja` picks one TU + the link).

Binary sizes differ as expected (78,737,554 B vs the CI artifact's 5,396,992 B): MSVC's CI build
strips debug info, ours is `-g0` but keeps every shim translation unit and static libstdc++.

## What the port needed

Everything below is in `../port/` — `leonida-mingw-port.patch` is the source diff (4 files), the
rest is the out-of-tree toolchain, the generated headers and the patch scripts.

1. **`runtime/CMakeLists.txt` is MSVC-only.** 662 `/switch`-style compile and link options with no
   compiler guard; GCC reads `/O2` as an output filename. `patch_cmakelists.py` wraps each one in
   `$<$<CXX_COMPILER_ID:MSVC>:…>`. Two follow-ups it got wrong and were fixed by hand: the
   variable-valued `/BASE:${GTA6RT_HOST_BASE}` and `/STACK:${GTA6RT_STACK}` had to stay wrapped
   (`patch_cmakelists.py` mangled `/STACK:` into `STACK:`), and `GTA6RT_HOST_BASE` is itself a
   `/BASE:…` string, so it must not be double-wrapped.
2. **The entry point.** `src/main.cpp:65` is a console `wmain`. MinGW chooses its startup object
   from `-municode`, and `-municode` alone produces a GUI image whose entry is `wWinMain`;
   `-mconsole --entry,wmainCRTStartup` fails to link ("cannot find entry symbol"). The pair
   `-mconsole -municode` **per target** works, and must not go into the global linker flags or
   every `int main()` probe CMake builds for itself breaks.
3. **GCC has no SEH here.** `__try`/`__except` fail to compile in C *and* C++ under every flag
   combination we probed (`seh_probe.c`). `mingw_compat.h` maps them to `try` / `catch (…)`.
   This changes semantics (a `__except` filter that returns `EXCEPTION_EXECUTE_HANDLER` for a
   specific code now catches everything) — acceptable for a bring-up port, worth a comment
   upstream.
4. **`__uuidof`.** GCC 16 has no `__uuidof`. `gen_uuidof.py` parses the Agility `d3d12.h` /
   `dxgi` headers and generates `mingw_uuidof_d3d.h`: 392 interfaces, one `inline constexpr GUID`
   each, and `#define __uuidof(type) (::leonida::uuidof<__typeof(type)>::value)`. Spot-checked
   against the SDK: `ID3D12Device 189819f1-…-1339b85f7`, `IDXGIFactory7 a4966eed-…-7afb20a8`.
   Specialising MinGW's own `__mingw_uuidof` instead does not work: `_MSC_VER` flips
   `_mingw.h:67-71` to `USE___UUIDOF=1` and disables its `__uuidof` mapping entirely.
5. **Header projection.** `patch_d3d_headers.py` reduces the 38
   `#if defined(_MSC_VER) || !defined(_WIN32)` guards in the Agility headers to the MSVC branch
   and repoints the Agility include at the patched copy, so the same headers feed the stub
   generator (cache variable `LEONIDA_D3D12_HEADER`).
6. **`_MSC_VER=1943` has side effects on the C++ standard headers.** Defining it renames the PE
   union members (`DUMMYUNIONNAME` and friends), which the runtime uses by their MSVC names: pass
   `-DDUMMYUNIONNAME= -DDUMMYUNIONNAME2= -DDUMMYUNIONNAME3= -DDUMMYSTRUCTNAME= -DDUMMYSTRUCTNAME2=`.
   `DEFINE_ENUM_FLAG_OPERATORS` in MinGW is not `constexpr`, so `mingw_compat.h` provides a
   `constexpr` version (it must not `#include <windows.h>`: the lean `windows.h` does not pull in
   `combaseapi.h` and force-including it breaks COM template bodies).
7. **Three real source bugs surfaced by the port** (each still needed in the current tree):
   - `runtime/shims/d3d12_vulkan_device.cpp:4649` guards `<experimental/coroutine>`-style MSVC
     intrinsics with `#if defined(_MSC_VER) || !defined(_WIN32)`, i.e. "not Windows" — under
     MinGW+`_MSC_VER` that is the wrong branch; the guard now also accepts
     `LEONIDA_MINGW_MSVCPROJ`.
   - `runtime/src/tls_host.cpp:14` used `__declspec(thread)` only for MSVC and `ThreadLocalStorage`
     elsewhere; GCC's `__thread` is what the TLS directory needs. The DLL grew from 118,759 B to
     137,620 B once fixed, i.e. it now really carries a TLS directory.
   - `third_party/xtaskqueue/.../WaitTimer_win32.cpp:110-111` assigns to a `LARGE_INTEGER`
     `.QuadPart` through a cast GCC rejects; split into `LowPart`/`HighPart`.
8. **`d3dkmthk.h` is missing in MinGW** (the driver-version diagnostic at `d3d12_vulkan_device.cpp`
   uses `D3DKMTQueryAdapterInfo(KMTQAITYPE_UMD_DRIVER_VERSION)`). `port/d3dkmthk_stub.h` declares
   the four structures and three functions. Measured here: the query fails for **every** type
   (`kmthk_probe.c`), so that diagnostic degrades to 0 rather than misreporting.

## One unresolved portability hazard, flagged not fixed

The placeholder path (`shims/xmem.cpp:185-197, 338, 376`) needs `VirtualAlloc2` /
`MapViewOfFile3` / `UnmapFileMapping2` and the `MEM_RESERVE_PLACEHOLDER` bit.
**MinGW's `winnt.h:5721` defines `MEM_RESERVE_PLACEHOLDER` as `0x40000`**, while the Windows SDK
and the docs use `0x00080000` (which is also `MEM_RESET`). Measured on this host with
`port`-adjacent probes (`H:\leonida\ph_probe_run.txt`, `H:\leonida\ph_probe2_run.txt`):

- `VirtualAlloc2`, `MapViewOfFile3`, `UnmapViewOfFile2` all resolve from `kernelbase.dll`.
- `MEM_RESERVE | 0x40000` + `PAGE_NOACCESS` → succeeds; + `PAGE_READWRITE` → `NULL` / `87`.
- `MEM_RESERVE | 0x80000` + `PAGE_NOACCESS` → `NULL` / `87` (consistent with `MEM_RESET`).
- `VirtualAlloc(…, MEM_LARGE_PAGES, …)` → `NULL` / `1314` `ERROR_PRIVILEGE_NOT_HELD`, which is
  why `xmem.cpp:442-450` deliberately only *aligns* 2 MiB guest pages instead of asking the host
  for large pages.

Nobody should rely on the physical-page window path under MinGW until someone settles which
value the OS treats as the placeholder bit. It does not matter for the current boot stop: none of
the seven `XMemVirtualAlloc` calls the title reaches before the stop carry either bit (their
`allocationType` values are `0x20402000`, `0x20003000`, `0x20403000` — see 0009).

## Reproducing

```
conda create -n leonida-rt -c conda-forge gcc gxx cmake ninja make binutils    # Scripts/conda.exe, not _conda.exe
# PATH must contain <env>/Library/bin AND <env>/Library/x86_64-w64-mingw32/bin,
# otherwise as.exe dies with exit 1 and no message.
python port/patch_d3d_headers.py && python port/gen_uuidof.py && python port/patch_cmakelists.py
cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=port/leonida-mingw-toolchain.cmake -S Leonida-continued/runtime -B rt-build
ninja -C rt-build -j 14 gta6rt gta6rt_tls_host
```

`build_mingw.cmd` does the wipe+configure+build; `build_only.cmd` is the ~1 minute incremental
loop. The toolchain file needs `CMAKE_MAKE_PROGRAM` as `CACHE FILEPATH … FORCE` (CMake 4.5
otherwise leaves it empty), and `-mxsave` (for `_xgetbv`), `-fpermissive`, `-Wa,-mbig-obj`
(the shim translation units exceed 65 535 sections), `-finput-charset=UTF-8 -fexec-charset=UTF-8`.
