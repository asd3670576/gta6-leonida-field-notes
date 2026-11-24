"""Derive a single-projection copy of the vendored D3D12 headers.

Why this exists, in three measured facts about the tree and the headers:

1. The Windows SDK's d3d12.h (here: Microsoft.Direct3D.D3D12 from NuGet,
   build/native/include) projects a COM method that returns a small struct
   through an `[out]` parameter behind a compiler test, e.g. d3d12.h:5444

       #if defined(_MSC_VER) || !defined(_WIN32)
           virtual D3D12_RESOURCE_DESC STDMETHODCALLTYPE GetDesc(void) = 0;
       #else
           virtual D3D12_RESOURCE_DESC *STDMETHODCALLTYPE GetDesc(D3D12_RESOURCE_DESC *RetVal) = 0;
       #endif

   and it does this for 38 methods across d3d12.h, d3d12video.h,
   d3d12compiler.h, d3dx12_core.h and d3dx12_resource_helpers.h.

2. runtime/shims/d3d12_vulkan_device.cpp implements some of those **unguarded**
   in the MSVC form (:2825 heap GetDesc, :5530 GetAdapterLuid, :5540
   GetCustomHeapProperties, :7516-7527 GetResourceAllocationInfo[12]) and one
   **guarded** (:4649, `#if defined(_MSC_VER) || !defined(_WIN32)`, both sides
   written). So the build must define _MSC_VER for the source; a plain MinGW
   build fails with "marked 'override', but does not override" on the unguarded
   ones, and a `_MSC_VER`-only-inside-the-header build fails on the guarded one.

3. tools/gen_d3d12_stubs.py parses the header as text and, when a method is
   declared in both branches (its own comment at :125-126 says it counts that as
   one slot), keeps the last spelling - the `#else` one. The generated
   d3d12_stubs.h therefore disagrees with the header whenever _MSC_VER is set.

So the compile gets the real header plus -D_MSC_VER, and the generator gets this
derived copy where each such guard is reduced to its MSVC branch. One projection,
three consumers.

Usage: python patch_d3d_headers.py [src_include_dir] [out_include_dir]
Idempotent: the output directory is rebuilt from the source every run.
"""
import re
import shutil
import sys
from pathlib import Path

SRC = Path(sys.argv[1] if len(sys.argv) > 1 else r"H:\leonida\agility\build\native\include")
DST = Path(sys.argv[2] if len(sys.argv) > 2 else r"H:\leonida\d3d12-msvc-projection")

# `#if defined(_MSC_VER) || !defined(_WIN32)` ... `#else` ... `#endif`
GUARD = re.compile(
    r"#if\s+defined\(_MSC_VER\)\s*\|\|\s*!defined\(_WIN32\)\n"      # the test
    r"(?P<msvc>.*?)"                                                # MSVC branch
    r"#else\n(?:.*?\n)*?"                                           # other branch
    r"#endif\n",
    re.S,
)

if DST.exists():
    shutil.rmtree(DST)
DST.mkdir(parents=True)

total = 0
files = 0
for p in sorted(SRC.rglob("*.h")):
    text = p.read_text(encoding="utf-8", errors="replace")
    new, n = GUARD.subn(lambda m: m.group("msvc"), text)
    rel = p.relative_to(SRC)
    out = DST / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(new, encoding="utf-8")
    if n:
        print(f"{rel}: reduced {n} guard(s) to the MSVC projection")
        total += n
        files += 1

print(f"wrote {DST}: {files} header(s) reduced, {total} guard(s) removed")
