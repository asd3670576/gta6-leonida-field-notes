/* MinGW compatibility shim for building the Leonida runtime with conda-forge
 * GCC. Force-included with -include by H:\leonida\leonida-mingw-toolchain.cmake.
 *
 * Two separate jobs, both measured on this machine:
 *
 * 1) DEFINE_ENUM_FLAG_OPERATORS. MinGW's copy (sysroot/usr/include/winnt.h:695)
 *    is defined unconditionally inside `#ifdef __cplusplus` and its operators
 *    are NOT constexpr, while the Windows SDK's are. The runtime relies on the
 *    SDK shape - runtime/shims/d3d12_vulkan_device.cpp:8323 writes
 *        constexpr UINT buffer_flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | ...
 *    which otherwise fails with "call to non-'constexpr' function".
 *    winnt.h redefines the macro unconditionally, so a command-line -D loses;
 *    including winnt.h here first and redefining afterwards wins, because every
 *    later expansion (d3d12.h, d3d12video.h, d3dcommon.h) sees our version.
 *
 * 2) The D3D12 C++ projection. The SDK's d3d12.h picks the projection per
 *    method behind a compiler test, e.g. d3d12.h:5444
 *        #if defined(_MSC_VER) || !defined(_WIN32)
 *            virtual D3D12_RESOURCE_DESC STDMETHODCALLTYPE GetDesc(void) = 0;
 *        #else
 *            virtual D3D12_RESOURCE_DESC *STDMETHODCALLTYPE GetDesc(D3D12_RESOURCE_DESC *RetVal) = 0;
 *        #endif
 *    and the shims are written against the MSVC side of that choice:
 *    d3d12_vulkan_device.cpp:2825 (heap GetDesc), :5530 (GetAdapterLuid),
 *    :5540 (GetCustomHeapProperties), :7516-7527 (GetResourceAllocationInfo[12]),
 *    and the calls at :6212 and :8938. Under plain GCC every one of those comes
 *    out "marked 'override', but does not override".
 *    Forcing `#if 1` is wrong - the same file also contains guards whose MSVC
 *    branch is the *out-parameter* form (ID3D12ShaderCacheSession::GetDesc at
 *    d3d12_vulkan_device.cpp:4652 is written that way), so the per-method
 *    choice has to stay. Defining _MSC_VER only around the D3D12 includes makes
 *    the header do its own job correctly. windows.h is parsed first, without
 *    _MSC_VER, so MinGW's own headers never take an MSVC path.
 */
#pragma once

#ifdef __cplusplus
/* winnt.h needs the minwindef.h macros (CONST, FAR, NEAR); windef.h provides
 * them without pulling in all of windows.h. */
#include <windef.h>
#include <winnt.h>

#undef DEFINE_ENUM_FLAG_OPERATORS
#define DEFINE_ENUM_FLAG_OPERATORS(ENUMTYPE) \
extern "C++" { \
inline constexpr ENUMTYPE operator | (ENUMTYPE a, ENUMTYPE b) { return ENUMTYPE(((int)a) | ((int)b)); } \
inline constexpr ENUMTYPE &operator |= (ENUMTYPE &a, ENUMTYPE b) { return (ENUMTYPE &)(((int &)a) |= ((int)b)); } \
inline constexpr ENUMTYPE operator & (ENUMTYPE a, ENUMTYPE b) { return ENUMTYPE(((int)a) & ((int)b)); } \
inline constexpr ENUMTYPE &operator &= (ENUMTYPE &a, ENUMTYPE b) { return (ENUMTYPE &)(((int &)a) &= ((int)b)); } \
inline constexpr ENUMTYPE operator ~ (ENUMTYPE a) { return ENUMTYPE(~((int)a)); } \
inline constexpr ENUMTYPE operator ^ (ENUMTYPE a, ENUMTYPE b) { return ENUMTYPE(((int)a) ^ ((int)b)); } \
inline constexpr ENUMTYPE &operator ^= (ENUMTYPE &a, ENUMTYPE b) { return (ENUMTYPE &)(((int &)a) ^= ((int)b)); } \
}

/* SEH. This toolchain has no structured exception handling at all - measured:
 * `__try` is "undeclared" in both C and C++, in -std=gnu++20, with
 * -fms-extensions and with -D_MSC_VER, so it is a build-configuration gap in the
 * conda-forge gcc 16.2.0 win-64 package, not a language-mode choice.
 *
 * The runtime's uses are of two kinds, and only one needs a translation:
 *   - shims/startup_trace.h:218 already picks its RAII branch when _MSC_VER is
 *     absent, so it never reaches __try here;
 *   - src/pe_loader.cpp:655-683 guards four probes of *another* thread's TEB
 *     slots (a thread that has ended may have freed them). Those spellings are
 *     unconditional, so translate them into the C++ equivalents textually.
 *
 * The trade-off is stated for the record: MinGW's C++ unwinder does not turn a
 * hardware access fault into a catchable exception, so `catch (...)` here
 * protects against a C++ exception, not against the guard-page fault SEH would
 * have caught. On the path measured so far (boot halts at the console memory
 * attributes, before any thread teardown) none of these probes takes the fault
 * path; if one ever does, the process dies loudly instead of reporting the dead
 * thread, which is the difference between a crash and a wrong answer later on. */
#if defined(__GNUC__) && !defined(_MSC_FULL_VER)
#ifndef __try
#define __try try
#endif
#ifndef __except
#define __except(x) catch (...)
#endif
#endif

/* MSVC's frame intrinsics. MinGW declares _ReturnAddress and
 * _AddressOfReturnAddress (winnt.h:1658 pulls x86intrin.h in, which is why they
 * compile and only fail at the link: "undefined reference to `_ReturnAddress'")
 * but this toolchain builds no definition. The call sites want exactly what
 * GCC's builtins give:
 *   shims/file_system.cpp:712/719/743/750 and shims/xmem.cpp:90/589 pass
 *     _ReturnAddress() to the note_* helpers, i.e. the caller's address;
 *   shims/registry.cpp:165 hands _AddressOfReturnAddress() to g_test_hook, a
 *     pointer that only runtime/test/unimplemented_policy_test ever reads, so
 *     the frame address stands in for it without changing any shipped
 *     behaviour.
 * GCC's builtins give the same values. Declared as plain extern functions by
 * intrin.h:522/582 (`__MACHINE(X) X;`), so the fix is a definition, not a macro:
 * a macro would also be substituted into that declaration and break it
 * ("macro `_ReturnAddress' passed 1 arguments, but takes just 0"). `extern "C"
 * inline` matches the declaration, is ODR-safe across translation units, and
 * gets inlined, which is what makes __builtin_return_address(0) describe the
 * shim's own frame exactly as MSVC's intrinsic does. */
#if defined(__GNUC__) && !defined(_MSC_FULL_VER)
extern "C" inline void *_ReturnAddress(void) { return __builtin_return_address(0); }
extern "C" inline void *_AddressOfReturnAddress(void) { return __builtin_frame_address(0); }
#endif

/* windows.h is deliberately NOT included here. It pulls objbase.h -> urlmon.h ->
 * servprov.h and unknwnbase.h, whose C++ templates call __uuidof; GCC 16 rejects
 * that name in an uninstantiated template body ("[-Wtemplate-body]"), and a
 * force-included header applies to CMake's own try-compile too, so the probe
 * `int main() {}` would stop configuring. The translation units that want COM
 * base classes include windows.h themselves, and -fpermissive (set by the
 * toolchain, as GCC's own note suggests) covers the template bodies there. */
#endif
