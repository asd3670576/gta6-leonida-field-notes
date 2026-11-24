"""Generate the __uuidof specializations this build needs.

Why this exists, measured on this machine:

  - The runtime writes MSVC's __uuidof in ~200 places (shims/d3d12_com_object.h:39
    inside a template pack, shims/d3d12_xs_device.cpp, shims/dxgi_com.cpp and the
    tests). __uuidof is a keyword in MSVC, where MIDL_INTERFACE(x) is
    __declspec(uuid(x)) and the compiler resolves it.
  - MinGW already provides the same surface for GCC, and better than a plain
    macro would: _mingw.h:559 spells
        #define __uuidof(type) __mingw_uuidof<__typeof(type)>()
    which accepts a type *and* an expression - so combaseapi.h:84's
    IID_PPV_ARGS(ppType) -> __uuidof(**(ppType)) works unmodified. The primary
    templates live in guiddef.h:28-36, behind `USE___UUIDOF == 0`, which
    _mingw.h:67-71 gives whenever _MSC_VER is not defined. This build does not
    define _MSC_VER (see leonida-mingw-toolchain.cmake for the three things that
    break when it is), so that path is live.
  - What MinGW does *not* provide is the specializations: its d3d12.h has no
    __mingw_uuidof line at all, and the D3D12 headers this build uses are the
    Agility SDK's. So the specializations are generated here, one per interface,
    from the headers themselves.

Each interface also gets one forward declaration, so the specialization does not
depend on which headers a translation unit included and in what order:
specializing a class template on an incomplete type is legal, and every one of
these names is declared `struct` by both the SDK and MinGW, so the
elaborated-type kinds agree.

GUIDs are read from whichever spelling a given header uses:
  MIDL_INTERFACE("guid") [decoration] struct NAME          (MinGW's style)
  MIDL_INTERFACE("guid") NAME : public BASE                (the SDK's style)
  DEFINE_GUID(IID_NAME, 0x..., 0x..., 0x..., 0xNN, ...)     (MinGW's DXGI set)

Usage: python gen_uuidof.py [out_header]
"""
import re
import sys
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else r"H:\leonida\mingw_uuidof_d3d.h")

MINGW_INC = Path(r"C:/Users/L.S/AppData/Local/miniforge3/envs/leonida-rt/Library/x86_64-w64-mingw32/sysroot/usr/include")
PROJ = Path(r"H:/leonida/d3d12-msvc-projection")

WANTED = [
    PROJ / "d3d12.h", PROJ / "d3d12video.h", PROJ / "d3d12sdklayers.h",
    PROJ / "d3d12compatibility.h", PROJ / "d3d12shader.h", PROJ / "d3d12compiler.h",
    PROJ / "d3dx12" / "d3dx12_core.h",
    MINGW_INC / "dxgi.h", MINGW_INC / "dxgi1_2.h", MINGW_INC / "dxgi1_3.h",
    MINGW_INC / "dxgi1_4.h", MINGW_INC / "dxgi1_5.h", MINGW_INC / "dxgi1_6.h",
    MINGW_INC / "dxgidebug.h", MINGW_INC / "d3d10.h", MINGW_INC / "d3d10_1.h",
    MINGW_INC / "d3d11.h", MINGW_INC / "unknwnbase.h", MINGW_INC / "objidl.h",
    MINGW_INC / "d3d12.h", MINGW_INC / "d3d12video.h", MINGW_INC / "d3d12sdklayers.h",
    MINGW_INC / "d3d12shader.h",
]

GUID_TXT = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

DECL = re.compile(
    r"""MIDL_INTERFACE\(\s*\"(""" + GUID_TXT + r""")\"\s*\)
        (?:[^\s;{(][^;{}()]{0,160}?)?
        \b(?:struct|class|interface)\s+([A-Za-z_][A-Za-z0-9_]*)""",
    re.VERBOSE | re.S,
)
DECL_NOKEY = re.compile(
    r"""MIDL_INTERFACE\(\s*\"(""" + GUID_TXT + r""")\"\s*\)\s*
        (?:extern\s+\"C\+\+\"\s*)?
        ([A-Za-z_][A-Za-z0-9_]*)\s*[:{]""",
    re.VERBOSE | re.S,
)
DEFINE_GUID = re.compile(
    r"DEFINE_GUID\(\s*IID_([A-Za-z0-9_]+)\s*,\s*"
    r"0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)\s*,\s*0x([0-9a-fA-F]+)\s*,\s*"
    r"(?:0x([0-9a-fA-F]{1,2})\s*,\s*){8}",
)
TAILS = re.compile(r"0x([0-9a-fA-F]{1,2})")

found: dict[str, tuple[str, str]] = {}
for path in WANTED:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"skip {path}: {exc}")
        continue
    hits = 0
    for rx in (DECL, DECL_NOKEY):
        for m in rx.finditer(text):
            guid, name = m.group(1), m.group(2)
            if name not in found:
                found[name] = (guid, path.name)
                hits += 1
    for m in DEFINE_GUID.finditer(text):
        name = m.group(1)
        if name in found:
            continue
        d1, d2, d3 = (int(m.group(i), 16) for i in (2, 3, 4))
        tail = [int(g, 16) for g in TAILS.findall(m.group(0))[-8:]]
        found[name] = ("%08x-%04x-%04x-%02x%02x-%s" % (
            d1, d2, d3, tail[0], tail[1], "".join("%02x" % b for b in tail[2:])), path.name)
        hits += 1
    print(f"  {path.name}: +{hits}")

found.setdefault("IUnknown", ("00000000-0000-0000-c000-000000000046", "hardcoded"))
found.setdefault("ID3D10Blob", ("8ba5fb08-f19f-42a2-467c-2a9f62b634af", "hardcoded"))

# MinGW registers some interfaces itself - unknwnbase.h:97 has
# __mingw_uuidof<IUnknown>, and objidl.h/oleidl.h do the same for their own sets.
# Emitting those again is a hard "redefinition of 'constexpr const GUID&
# __mingw_uuidof()'" error, because our header is force-included and theirs is
# pulled in later by the translation unit's own <windows.h>. So read the list
# from the sysroot and skip it.
PROVIDED = re.compile(r"__mingw_uuidof<\s*([A-Za-z_][A-Za-z0-9_]*)\s*>")
already: set[str] = set()
for p in MINGW_INC.rglob("*.h"):
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        continue
    if "__mingw_uuidof<" in text:
        already.update(PROVIDED.findall(text))
skipped = sorted(n for n in found if n in already)
# Informational only: the table lives in namespace leonida, so a name MinGW also
# registers cannot collide, and dropping it would lose an entry the shims need
# (IUnknown is exactly such a case).
print(f"MinGW registers {len(already)} __mingw_uuidof name(s); overlap with our table: "
      f"{len(skipped)} ({', '.join(skipped[:6])})")

lines = [
    "/* Generated by H:/leonida/gen_uuidof.py - do not edit.",
    f" * {len(found)} interface uuid(s).",
    " *",
    " * MinGW spells __uuidof as __mingw_uuidof<__typeof(type)>(), whose primary",
    " * templates guiddef.h:28-36 declare when _MSC_VER is not defined (so that",
    " * USE___UUIDOF is 0, _mingw.h:67-71). All that is missing are the",
    " * specializations for the D3D12/DXGI interfaces - MinGW's d3d12.h registers",
    " * none - so they are added here. An interface that is not listed reaches the",
    " * undefined primary and fails to compile, which is the right diagnosis.",
    " */",
    "#pragma once",
    "",
    "#if defined(__cplusplus)",
    "#include <guiddef.h>",
    "",
    "/* Own namespace, own table: MinGW registers IUnknown, IClassFactory, IMarshal",
    "   and friends itself (unknwnbase.h:97, objidlbase.h:586, ...) through a macro,",
    "   so a second specialization of __mingw_uuidof<...> for those names is a hard",
    "   redefinition error. Nothing here can collide that way. */",
    "namespace leonida {",
    "template<class T> struct uuidof;   /* left undefined: an unregistered interface",
    "                                     is a compile error, not a wrong GUID */",
    "}  // namespace leonida",
    "",
    "/* Same shape as MinGW's own (_mingw.h:559): __typeof accepts a type and an",
    "   expression alike, which is what combaseapi.h:84's",
    "   IID_PPV_ARGS(ppType) -> __uuidof(**(ppType)) needs. Redefined after",
    "   guiddef.h -> _mingw.h have had their say, so this version wins. */",
    "#undef __uuidof",
    "#define __uuidof(type) (::leonida::uuidof<__typeof(type)>::value)",
    "",
]

for name in sorted(found):
    guid, src = found[name]
    p = guid.replace("-", "")
    d1, d2, d3 = int(p[0:8], 16), int(p[8:12], 16), int(p[12:16], 16)
    tail = ", ".join("0x%02x" % int(p[i:i + 2], 16) for i in range(16, 32, 2))
    lines += [
        f"struct {name};   /* uuid from {src} */",
        f"template <> struct leonida::uuidof<{name}> {{",
        f"  static constexpr ::GUID value {{ 0x{d1:08x}, 0x{d2:04x}, 0x{d3:04x}, {{ {tail} }} }};",
        "};",
        "",
    ]

lines += ["#endif  // __cplusplus", ""]
OUT.write_text("\n".join(lines), encoding="utf-8")
print(f"wrote {OUT} ({OUT.stat().st_size} bytes), {len(found)} interfaces")
for probe in ("ID3D12Device", "ID3D12Resource", "IDXGIFactory7", "ID3D12Device14", "ID3D12Fence1"):
    print(f"  {probe}: {found.get(probe, ('MISSING', ''))[0]}")
