// Does this host actually provide the placeholder APIs runtime/shims/xmem.cpp:185-197
// resolves at run time? available() needs all three, and xmem.cpp:376 turns a missing
// one into ERROR_NOT_SUPPORTED -> XMemVirtualAlloc returns NULL, which is one candidate
// explanation for the guest halting right after its XMemVirtualAlloc burst.
// Not a name lookup only test: it performs the same placeholder + view sequence the shim does.
#include <windows.h>
#include <stdio.h>

typedef PVOID(WINAPI *VA2)(HANDLE, PVOID, SIZE_T, ULONG, ULONG, MEM_EXTENDED_PARAMETER *, ULONG);
typedef PVOID(WINAPI *MVF3)(HANDLE, HANDLE, PVOID, ULONG64, SIZE_T, ULONG, ULONG, MEM_EXTENDED_PARAMETER *, ULONG);
typedef BOOL(WINAPI *UMV2)(HANDLE, PVOID, ULONG);

#define MEM_RESERVE_PLACEHOLDER_ 0x00080000
#define MEM_REPLACE_PLACEHOLDER_ 0x00004000

int main(void) {
    HMODULE kb = GetModuleHandleW(L"kernelbase.dll");
    printf("kernelbase.dll handle = %p\n", (void *)kb);
    if (!kb) { printf("no kernelbase handle: %lu\n", GetLastError()); return 1; }

    const char *names[] = {"VirtualAlloc2", "MapViewOfFile3", "UnmapViewOfFile2", "GetLocalNumaNodeInfo"};
    for (unsigned i = 0; i < sizeof names / sizeof *names; ++i) {
        SetLastError(0);
        FARPROC f = GetProcAddress(kb, names[i]);
        printf("  %-24s %-8s lasterr=%lu\n", names[i], f ? "FOUND" : "missing", GetLastError());
    }

    VA2 va2 = (VA2)GetProcAddress(kb, "VirtualAlloc2");
    MVF3 mvf3 = (MVF3)GetProcAddress(kb, "MapViewOfFile3");
    UMV2 umv2 = (UMV2)GetProcAddress(kb, "UnmapViewOfFile2");
    if (!va2 || !mvf3 || !umv2) { printf("available()=false -> shim returns NULL\n"); return 0; }

    // 1) reserve a placeholder, the way reserve_physical_window does (xmem.cpp:338).
    SetLastError(0);
    PVOID ph = va2(GetCurrentProcess(), NULL, 0x10000, MEM_RESERVE | MEM_RESERVE_PLACEHOLDER_, PAGE_NOACCESS, NULL, 0);
    printf("VirtualAlloc2(64K placeholder) = %p  lasterr=%lu\n", ph, GetLastError());
    if (!ph) return 0;

    // 2) commit 2 MiB pages the way a kXmemLargePages allocation does.
    SetLastError(0);
    PVOID big = va2(GetCurrentProcess(), NULL, 0x200000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, NULL, 0);
    printf("VirtualAlloc2(2M commit)        = %p  lasterr=%lu\n", big, GetLastError());

    // 3) back the placeholder with a section and map a view over it (xmem.cpp:480).
    HANDLE sec = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE | SEC_RESERVE, 0, 0x10000, NULL);
    printf("section = %p  lasterr=%lu\n", (void *)sec, GetLastError());
    if (sec) {
        SetLastError(0);
        PVOID view = mvf3(sec, GetCurrentProcess(), ph, 0, 0x10000, MEM_REPLACE_PLACEHOLDER_, PAGE_READWRITE, NULL, 0);
        printf("MapViewOfFile3 over placeholder = %p  lasterr=%lu\n", view, GetLastError());
        if (view) {
            *(volatile char *)view = 0x5a;
            printf("view writable: byte=%02x\n", (unsigned char)*(volatile char *)view);
            printf("UnmapViewOfFile2 = %d lasterr=%lu\n", umv2(GetCurrentProcess(), view, 0), GetLastError());
        }
        CloseHandle(sec);
    }
    VirtualFree(ph, 0, MEM_RELEASE);
    if (big) VirtualFree(big, 0, MEM_RELEASE);
    printf("placeholder APIs work on this host\n");
    return 0;
}
