// Which D3D12 runtime can this Windows 10 actually take, and what shader model does each give?
//
// Context: XCL (github.com/ivall/xcl) needs Shader Model 6.6 for the title's shaders. On this
// machine it reports "no SM 6.6 (Agility SDK unavailable: ID3D12SDKConfiguration1 unavailable
// (update Windows 10 to 22H2 KB5029331+): 不支持此接口 (0x80004002)) (has 6.5): shaders cannot
// run" - it only knows the *CreateDeviceFactory* route, which the OS gained in KB5029331
// (19045.3393); this box is 19045.3324. The older, still-supported route is the classic pair of
// data exports in the host executable (D3D12SDKVersion ordinal 1, D3D12SDKPath ordinal 2) plus a
// D3D12\ folder next to it. This probe answers whether that route works here, and for which
// Agility version.
//
// Build matrix (see agility_matrix.cmd): -DAGILITY_VERSION=<n> exports that version,
// -DNO_AGILITY_EXPORTS compiles the two symbols as plain variables (true baseline).
// d3d12.dll is loaded dynamically: linking against MinGW's d3d12 import lib dies at process
// start with 0xC0000139 here.
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <tlhelp32.h>
#include <cstdio>
#include <cstring>

typedef HRESULT(WINAPI *CreateDeviceFn)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);

#ifdef NO_AGILITY_EXPORTS
unsigned long D3D12SDKVersion = 0;
char D3D12SDKPath[] = "";
#elif defined(USE_DEF_EXPORTS)
// Exported through a .def fed to dlltool, so the ordinals are 1 and 2 as the D3D12 runtime
// expects (GNU ld assigns PE ordinals alphabetically for __declspec(dllexport), which would
// put D3D12SDKPath at ordinal 1).
unsigned long D3D12SDKVersion = AGILITY_VERSION;
char D3D12SDKPath[] = "D3D12\\";
#else
__declspec(dllexport) unsigned long D3D12SDKVersion = AGILITY_VERSION;
__declspec(dllexport) char D3D12SDKPath[] = "D3D12\\";
#endif

static const char *smName(D3D_SHADER_MODEL m) {
    switch (m) {
        case D3D_SHADER_MODEL_6_0: return "6.0";
        case D3D_SHADER_MODEL_6_1: return "6.1";
        case D3D_SHADER_MODEL_6_2: return "6.2";
        case D3D_SHADER_MODEL_6_3: return "6.3";
        case D3D_SHADER_MODEL_6_4: return "6.4";
        case D3D_SHADER_MODEL_6_5: return "6.5";
        case D3D_SHADER_MODEL_6_6: return "6.6";
        case D3D_SHADER_MODEL_6_7: return "6.7";
        default: return "unknown";
    }
}

static void list_d3d12_modules(void) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    if (snap == INVALID_HANDLE_VALUE) return;
    MODULEENTRY32W me{};
    me.dwSize = sizeof me;
    if (Module32FirstW(snap, &me)) {
        do {
            char name[128], path[1024];
            name[0] = 0;
            path[0] = 0;
            WideCharToMultiByte(CP_UTF8, 0, me.szModule, -1, name, sizeof name, NULL, NULL);
            WideCharToMultiByte(CP_UTF8, 0, me.szExePath, -1, path, sizeof path, NULL, NULL);
            if (strstr(name, "D3D12") || strstr(name, "d3d12"))
                std::printf("  module: %-16s %s\n", name, path);
        } while (Module32NextW(snap, &me));
    }
    CloseHandle(snap);
}

// Print the host executable's own export directory: the D3D12 runtime reads these two exports
// BY ORDINAL (version at 1, path at 2), and we need to know what ordinals our linker actually
// assigned - dlltool's and ld's own reports were not conclusive here. The value at each
// exported address is printed too: 0x26c (=620) means the version, a 0x7ff… pointer means the
// string landed in the slot the loader wants the number in.
static void self_exports(void) {
    HMODULE me = GetModuleHandleA(NULL);
    if (!me) return;
    auto *dos = reinterpret_cast<IMAGE_DOS_HEADER *>(me);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) { std::printf("  self exports: bad dos header\n"); return; }
    auto *nt = reinterpret_cast<IMAGE_NT_HEADERS64 *>(reinterpret_cast<BYTE *>(me) + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) { std::printf("  self exports: bad nt header\n"); return; }
    auto &dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (dir.VirtualAddress == 0) { std::printf("  self exports: none\n"); return; }
    auto *e = reinterpret_cast<IMAGE_EXPORT_DIRECTORY *>(reinterpret_cast<BYTE *>(me) + dir.VirtualAddress);
    auto *funcs = reinterpret_cast<DWORD *>(reinterpret_cast<BYTE *>(me) + e->AddressOfFunctions);
    auto *ords = reinterpret_cast<WORD *>(reinterpret_cast<BYTE *>(me) + e->AddressOfNameOrdinals);
    auto *names = reinterpret_cast<DWORD *>(reinterpret_cast<BYTE *>(me) + e->AddressOfNames);
    std::printf("  self exports: base=%u named=%u total=%u\n", e->Base, e->NumberOfNames, e->NumberOfFunctions);
    for (DWORD i = 0; i < e->NumberOfNames; ++i) {
        const char *n = reinterpret_cast<const char *>(reinterpret_cast<BYTE *>(me) + names[i]);
        if (!strstr(n, "D3D12")) continue;
        WORD idx = ords[i];
        void *at = reinterpret_cast<BYTE *>(me) + funcs[idx];
        unsigned long long v = 0;
        memcpy(&v, at, sizeof v);
        std::printf("  self export: %-16s ordinal=%u  value=0x%llx\n", n,
                    static_cast<unsigned>(e->Base) + idx, v);
    }
}

int main(void) {
    std::printf("exports: D3D12SDKVersion=%lu D3D12SDKPath=\"%s\"\n", D3D12SDKVersion, D3D12SDKPath);
    self_exports();
    HMODULE d3d = LoadLibraryExW(L"d3d12.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!d3d) {
        std::printf("  LoadLibrary(d3d12.dll) FAILED err=%lu\n", GetLastError());
        list_d3d12_modules();
        return 1;
    }
    auto create = (CreateDeviceFn)GetProcAddress(d3d, "D3D12CreateDevice");
    if (!create) { std::printf("  no D3D12CreateDevice export\n"); return 1; }
    ID3D12Device *dev = NULL;
    HRESULT hr = create(NULL, D3D_FEATURE_LEVEL_12_0, IID_ID3D12Device, (void **)&dev);
    std::printf("  D3D12CreateDevice = 0x%08x\n", (unsigned)hr);
    list_d3d12_modules();
    if (FAILED(hr) || !dev) return 1;
    for (int i = 0; i < 3; ++i) {
        D3D_SHADER_MODEL ask[] = {D3D_SHADER_MODEL_6_5, D3D_SHADER_MODEL_6_6, D3D_SHADER_MODEL_6_7};
        D3D12_FEATURE_DATA_SHADER_MODEL q = {ask[i]};
        dev->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &q, sizeof q);
        std::printf("  highest shader model when asking for %s: %s\n", smName(ask[i]), smName(q.HighestShaderModel));
    }
    dev->Release();
    return 0;
}
