# MinGW-w64 (conda-forge GCC 16.2.0) toolchain for the Leonida runtime, on a
# machine with no Visual Studio and no administrator rights.
#
# Companion pieces (all measured on this machine):
#  - H:\leonida\patch_cmakelists.py wraps the ~180 MSVC-spelled switches in
#    runtime/CMakeLists.txt (`/W4 /permissive- /utf-8`, `/OPT:NOREF`, `/STACK:`,
#    `/BASE:`, `/FIXED`, `/ENTRY:`) in `$<$<CXX_COMPILER_ID:MSVC>:...>`. GCC
#    reads `/W4` as an input file name, and shadowing target_compile_options
#    from here does not work on CMake 4.5: there is no underscore escape for
#    that command, so the shadow recursed into itself.
#  - H:\leonida\build_mingw.cmd puts the env's Library\bin and
#    Library\x86_64-w64-mingw32\bin on PATH. Without that, as.exe fails with
#    exit 1 and prints nothing at all.
#  - The SDK gate at runtime/CMakeLists.txt:28-34 wants
#    D3D_ROOT_SIGNATURE_VERSION_1_2, which MinGW's d3d12.h lacks (SDK 10.0.26100
#    material). Microsoft's redistributable DirectX-Headers copy has it, so its
#    include dir goes in front via -isystem AND CMAKE_INCLUDE_PATH (the project
#    also runs a plain find_path for d3d12.h, which ignores compiler flags).
#    Its MIDL-generated headers ask for rpcndr.h 500 while MinGW ships 475,
#    hence -D__REQUIRED_RPCNDR_H_VERSION__=475.
#    Verified: Performing Test GTA6RT_SDK_HAS_ROOT_SIGNATURE_1_2 - Success.
#  - runtime/src/main.cpp:65 is the console `wmain`. GCC's -municode would pick
#    wWinMain (a GUI entry) and MinGW's default startup calls `main`, so the
#    entry is named outright in CMAKE_EXE_LINKER_FLAGS below - we build exactly
#    one executable (gta6rt; gta6rt_tls_host is a DLL and takes the shared
#    linker flags instead).

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

set(LEONIDA_MINGW_PREFIX "C:/Users/L.S/AppData/Local/miniforge3/envs/leonida-rt")
# The header set the code is actually written against: Microsoft's own
# Windows SDK d3d12.h, redistributed in the D3D12 Agility SDK NuGet
# (Microsoft.Direct3D.D3D12, build/native/include). It has both things this
# build needs and neither of the free alternatives has:
#   - D3D_ROOT_SIGNATURE_VERSION_1_2 / D3D12_ROOT_SIGNATURE_DESC2 (SDK 10.0.26100
#     material, the gate at runtime/CMakeLists.txt:28-34), and
#   - the by-value virtuals the shims override, e.g.
#         virtual D3D12_RESOURCE_DESC STDMETHODCALLTYPE GetDesc(void) = 0;
#     which is what runtime/shims/d3d12_vulkan_device.cpp:2825/5530/6212/8938
#     implements and calls. MinGW-w64's d3d12.h and microsoft/DirectX-Headers
#     both declare those vtable slots in the out-parameter form and add a
#     non-virtual inline wrapper instead, so every `override` in the shims fails
#     with "marked override but does not override" against them.
# d3dcommon.h and dxgiformat.h still come from the MinGW sysroot.
# Two copies of the same headers, because three consumers must agree on one
# projection (see H:/leonida/patch_d3d_headers.py for the measured detail):
#  - the compile gets the *derived* single-projection copy, and -D_MSC_VER below
#    so the shims' own `#if defined(_MSC_VER) || !defined(_WIN32)` (one guarded
#    override, at shims/d3d12_vulkan_device.cpp:4649) picks the same side;
#  - tools/gen_d3d12_stubs.py, which parses the header as text and keeps the
#    `#else` spelling when a method appears in both branches (its own comment at
#    :125-126), is handed the same derived copy through LEONIDA_D3D12_HEADER.
set(LEONIDA_DXHEADERS "H:/leonida/d3d12-msvc-projection")
set(LEONIDA_COMPAT_HDR "H:/leonida/mingw_compat.h")
set(LEONIDA_D3D12_HEADER "H:/leonida/d3d12-msvc-projection/d3d12.h" CACHE FILEPATH "d3d12.h for the stub generator")
set(LEONIDA_VKHEADERS "H:/leonida/vulkan-headers/include")
set(LEONIDA_MINGW_SYSROOT_LIB "${LEONIDA_MINGW_PREFIX}/Library/x86_64-w64-mingw32/sysroot/usr/lib")

set(CMAKE_C_COMPILER   "${LEONIDA_MINGW_PREFIX}/Library/bin/gcc.exe")
set(CMAKE_CXX_COMPILER "${LEONIDA_MINGW_PREFIX}/Library/bin/g++.exe")
# The Ninja generator reads CMAKE_MAKE_PROGRAM from the cache; a plain set() in
# a toolchain file left it empty and configure died with
#   Run Build Command(s): "" -v cmTC_...
set(CMAKE_MAKE_PROGRAM "${LEONIDA_MINGW_PREFIX}/Library/bin/ninja.exe" CACHE FILEPATH "ninja executable" FORCE)
set(CMAKE_AR           "${LEONIDA_MINGW_PREFIX}/Library/x86_64-w64-mingw32/bin/ar.exe")
set(CMAKE_RANLIB       "${LEONIDA_MINGW_PREFIX}/Library/x86_64-w64-mingw32/bin/ranlib.exe")
set(CMAKE_OBJCOPY      "${LEONIDA_MINGW_PREFIX}/Library/x86_64-w64-mingw32/bin/objcopy.exe")
set(CMAKE_RC_COMPILER  "${LEONIDA_MINGW_PREFIX}/Library/x86_64-w64-mingw32/bin/windres.exe")

# find_path / find_library do not consult compiler flags, so the D3D12 headers
# and MinGW's import libs (libd3d12.a, libdxgi.a, libpsapi.a, libole32.a,
# libws2_32.a, libbcrypt.a) are named here.
set(CMAKE_INCLUDE_PATH  "${LEONIDA_DXHEADERS}")
set(CMAKE_LIBRARY_PATH  "${LEONIDA_MINGW_SYSROOT_LIB}")

# The loader is a console program whose entry is `wmain` (runtime/src/main.cpp:65).
# GCC's -municode would pick wWinMain (a GUI entry) and MinGW's default startup
# calls `main`, so the entry is named directly. We build exactly one executable
# (gta6rt; gta6rt_tls_host is a DLL and takes the shared flags instead), so
# naming it here is safe.
# The entry/startup choice is per-target (runtime/CMakeLists.txt adds
# -mconsole -municode to gta6rt alone): -municode globally would break the
# `int main()` programs CMake compiles for its own compiler probes.
set(CMAKE_EXE_LINKER_FLAGS_INIT
    "-static-libgcc -static-libstdc++ -Wl,--image-base,0x10000000000 -Wl,--stack,8388608")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")

# UTF-8 sources on a code-page-936 machine (their own reason for /utf-8,
# CMakeLists.txt:7-12). -Wa,-mbig-obj: the D3D12 shim TUs are the /bigobj ones.
# -D_MSC_VER=1943 makes the *source* agree with the header projection: the shims
# write the by-value overrides unguarded in four places and guarded in one
# (shims/d3d12_vulkan_device.cpp:37, :4649), so pretending to be no compiler at
# all is not an option. 1943 = Visual Studio 2022 17.10, the toolset the
# project's own CI (runtime.yml "Set up MSVC x64 developer environment") lands on.
# Two force-included compatibility headers, in this order:
#   mingw_compat.h        constexpr DEFINE_ENUM_FLAG_OPERATORS (MinGW's is not)
#   mingw_uuidof_d3d.h    __uuidof(T) -> __mingw_uuidof<T>() plus 176+ interface
#                         specializations, because __uuidof is an MSVC keyword and
#                         MinGW's own d3d12.h/dxgi headers register no uuids at all
#                         (shims/d3d12_com_object.h:39, d3d12_xs_device.cpp and
#                         dxgi_com.cpp use it ~200 times).
# -D_MSC_VER=1943 is what makes two things work at once that this tree needs:
#   - SEH: GCC accepts `__try/__except` in C++ here only in the MSVC mode (with it
#     off, src/pe_loader.cpp:665-684 fails as "expected 'catch' before '__except'",
#     and shims/startup_trace.h:218 takes its portable branch instead - which is
#     fine there, but pe_loader's is not optional); and
#   - the D3D12/DXGI projection in the headers and in the one guarded source site
#     (shims/d3d12_vulkan_device.cpp:4649).
# The cost is that winnt.h:60-70 then names the anonymous unions in its PE and
# time structures DUMMYUNIONNAME/DUMMYSTRUCTNAME, and src/pe_loader.cpp:987/1811
# read `d->OriginalFirstThunk` and third_party/xtaskqueue reads `li.HighPart`
# straight through them. Those macros are `#ifndef`-guarded, so passing them
# empty from the command line puts the anonymous form back and both sides work.
# __uuidof is unaffected: gen_uuidof.py defines it itself (namespace leonida),
# which is also why MSVC's USE___UUIDOF=1 under _MSC_VER no longer matters.
# kmheaders supplies a stub d3dkmthk.h: MinGW ships none at all, and the runtime's
# only use of it (shims/dxgi_com.cpp:1080-1105, the UMD driver-version diagnostic)
# resolves all three entry points at run time and is documented to yield 0 when
# the query fails. Measured here: with the stub the query does fail for every
# KMTQAITYPE on this RTX 3080, so that one string degrades to 0 in this build
# while everything else about the adapter is read from Vulkan.
# -D_MSC_VER=1943 is required, not cosmetic: the shims spell the D3D12 vtable
# projection through the compiler (shims/dxgi_com.cpp:177 `#ifdef _MSC_VER`,
# shims/d3d12_vulkan_device.cpp:4649 `#if defined(_MSC_VER) || !defined(_WIN32)`),
# and several calls (d3d12_vulkan_device.cpp:6212 and :8938 `resource->GetDesc()`)
# are written unguarded on the MSVC side, so only that side compiles.
# Everything defining it used to break is now handled on its own terms:
#   PE/LARGE_INTEGER union members  -> -DDUMMYUNIONNAME= ... (winnt.h:60-70, #ifndef-guarded)
#   SEH                             -> __try/__except -> try/catch(...) in mingw_compat.h
#                                      (this GCC build has no SEH at all, in C either)
#   __uuidof                        -> H:/leonida/mingw_uuidof_d3d.h defines it itself,
#                                      so _mingw.h:67-71 turning USE___UUIDOF off under
#                                      _MSC_VER no longer costs anything
# -mxsave: src/host_cpu.cpp:47 calls the _xgetbv intrinsic, which MSVC allows
# unconditionally and GCC only exposes behind the xsave target option (otherwise
# "inlining failed in call to 'always_inline' '_xgetbv': target specific option
# mismatch"). It is a runtime check of XCR0, executed before any AVX use, so
# enabling the instruction set feature changes nothing about what the program
# does at run time - the AVX preflight in host_cpu.cpp still decides.
set(LEONIDA_COMMON_FLAGS "-include ${LEONIDA_COMPAT_HDR} -include H:/leonida/mingw_uuidof_d3d.h -D_MSC_VER=1943 -DDUMMYUNIONNAME= -DDUMMYUNIONNAME2= -DDUMMYUNIONNAME3= -DDUMMYSTRUCTNAME= -DDUMMYSTRUCTNAME2= -DLEONIDA_MINGW_MSVCPROJ -mxsave -fpermissive -finput-charset=UTF-8 -fexec-charset=UTF-8 -Wa,-mbig-obj -g0 -D__REQUIRED_RPCNDR_H_VERSION__=475 -isystem H:/leonida/kmheaders -isystem ${LEONIDA_DXHEADERS} -isystem ${LEONIDA_VKHEADERS}")
# -std=gnu++20, not c++20: runtime/src/pe_loader.cpp:665-684 uses SEH
# (`__try` / `__except`), which GCC only accepts as an extension - with strict
# -std=c++20 it fails as "expected 'catch' before '__except'". MSVC accepts both
# spellings, so this is a toolchain difference, not a code bug.
set(CMAKE_CXX_FLAGS_INIT "-std=gnu++20 ${LEONIDA_COMMON_FLAGS}")
set(CMAKE_C_FLAGS_INIT   "${LEONIDA_COMMON_FLAGS}")

# The loader is a console program whose entry is `wmain` (runtime/src/main.cpp:65).
set_property(DIRECTORY PROPERTY leonida_placeholder "")

# Vulkan: every entry point is loaded at run time (LOADD in
# runtime/test/vk_pipeline_check.cpp:1239 and in the shims), so headers are all
# that is needed at build time - no SDK, no import library.
set(Vulkan_INCLUDE_DIR "${LEONIDA_VKHEADERS}" CACHE PATH "Vulkan headers")
set(FETCHCONTENT_SOURCE_DIR_VULKANHEADERS "${LEONIDA_VKHEADERS}" CACHE PATH "pinned Vulkan-Headers copy")

set(BUILD_SHARED_LIBS OFF)
set(BUILD_TESTING OFF CACHE BOOL "skip the ~95 test binaries")
