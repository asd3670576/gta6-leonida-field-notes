// Variant probe: VirtualAlloc2 exists on this host (ph_probe_run.txt) but the placeholder
// reservation the xmem shim needs came back NULL with ERROR_INVALID_PARAMETER (87).
// Which combination is actually rejected here decides whether the guest's XMemVirtualAlloc
// burst failed for an OS reason, which upstream (Win11) would not have hit.
#include <windows.h>
#include <stdio.h>

typedef PVOID(WINAPI *VA2)(HANDLE, PVOID, SIZE_T, ULONG, ULONG, MEM_EXTENDED_PARAMETER *, ULONG);
typedef PVOID(WINAPI *MVF3)(HANDLE, HANDLE, PVOID, ULONG64, SIZE_T, ULONG, ULONG, MEM_EXTENDED_PARAMETER *, ULONG);

#ifndef MEM_RESERVE_PLACEHOLDER
#define MEM_RESERVE_PLACEHOLDER 0x00080000
#endif
#ifndef MEM_REPLACE_PLACEHOLDER
#define MEM_REPLACE_PLACEHOLDER 0x00004000
#endif
#ifndef MEM_COALESCE_PLACEHOLDER
#define MEM_COALESCE_PLACEHOLDER 0x02000000
#endif

static CHAR g_buf[0x200000];

void show(const char *label, PVOID p) {
    DWORD e = GetLastError();
    printf("%-58s -> %p  lasterr=%lu%s\n", label, p, e, e ? " (FAILED)" : "");
}

int main(void) {
    OSVERSIONINFOEXW v{sizeof v};
    // RtlGetVersion is the only one that reports 10.0 truthfully after the manifest dance.
    if (HMODULE nt = GetModuleHandleW(L"ntdll.dll")) {
        typedef LONG(WINAPI * RtlGetVersionP)(PRTL_OSVERSIONINFOW);
        if (auto f = (RtlGetVersionP)GetProcAddress(nt, "RtlGetVersion")) {
            f((PRTL_OSVERSIONINFOW)&v);
            printf("host build=%lu sp=%lu  (MEM_RESERVE_PLACEHOLDER=0x%x MEM_REPLACE_PLACEHOLDER=0x%x)\n",
                   v.dwBuildNumber, (unsigned)v.wServicePackMajor, (unsigned)MEM_RESERVE_PLACEHOLDER,
                   (unsigned)MEM_REPLACE_PLACEHOLDER);
        }
    }

    HMODULE kb = GetModuleHandleW(L"kernelbase.dll");
    VA2 va2 = (VA2)GetProcAddress(kb, "VirtualAlloc2");
    MVF3 mvf3 = (MVF3)GetProcAddress(kb, "MapViewOfFile3");

    show("VirtualAlloc2 64K MEM_RESERVE only, RW", va2(GetCurrentProcess(), NULL, 0x10000, MEM_RESERVE,
                                                       PAGE_READWRITE, NULL, 0));
    show("VirtualAlloc2 64K MEM_RESERVE|PLACEHOLDER, RW",
         va2(GetCurrentProcess(), NULL, 0x10000, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER, PAGE_READWRITE, NULL, 0));
    show("VirtualAlloc2 64K MEM_RESERVE|PLACEHOLDER, NOACCESS",
         va2(GetCurrentProcess(), NULL, 0x10000, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER, PAGE_NOACCESS, NULL, 0));
    show("VirtualAlloc2 1M MEM_RESERVE|PLACEHOLDER, NOACCESS",
         va2(GetCurrentProcess(), NULL, 0x100000, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER, PAGE_NOACCESS, NULL, 0));
    show("VirtualAlloc2 2M MEM_RESERVE|COMMIT, RW",
         va2(GetCurrentProcess(), NULL, 0x200000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL, 0));

    // Placeholder backed by an existing replacement block (a section reservation).
    HANDLE sec = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 0x10000, NULL);
    if (sec) {
        PVOID backing = va2(GetCurrentProcess(), NULL, 0x10000, MEM_RESERVE, PAGE_READWRITE, NULL, 0);
        show("VirtualAlloc2 backing for section", backing);
        HANDLE block = NULL;
        // Reserve a placeholder over the section: MEM_RESERVE|MEM_RESERVE_PLACEHOLDER with a section
        // passed as the process handle is the MapViewOfFile3 style, so try the documented form instead:
        show("VirtualAlloc2 placeholder WITH section as replacement block",
             va2(sec, NULL, 0x10000, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER, PAGE_READWRITE, NULL, 0));
        (void)block;
        if (backing) {
            show("MapViewOfFile3 over that backing (MEM_REPLACE_PLACEHOLDER)",
                 mvf3(sec, GetCurrentProcess(), backing, 0, 0x10000, MEM_REPLACE_PLACEHOLDER, PAGE_READWRITE, NULL, 0));
        }
        CloseHandle(sec);
    }

    // Baseline: the classic API, to be sure this is about placeholders and not about VirtualAlloc2 itself.
    show("VirtualAlloc 64K MEM_RESERVE|MEM_COMMIT classic",
         VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
    show("VirtualAlloc 2M MEM_RESERVE|MEM_COMMIT|MEM_LARGE_PAGES",
         VirtualAlloc(NULL, 0x200000, MEM_RESERVE | MEM_COMMIT | MEM_LARGE_PAGES, PAGE_READWRITE));
    return 0;
}
