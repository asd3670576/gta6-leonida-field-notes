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

int main(void) {
    std::printf("exports: D3D12SDKVersion=%lu D3D12SDKPath=\"%s\"\n", D3D12SDKVersion, D3D12SDKPath);
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
