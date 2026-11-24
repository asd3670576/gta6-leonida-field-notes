/* Minimal d3dkmthk.h for building the Leonida runtime with MinGW, which ships
 * no version of it at all (measured: no d3dkmt* file in the sysroot, and no
 * KMTQAITYPE line anywhere in it).
 *
 * The runtime's only use is runtime/shims/dxgi_com.cpp:1080-1105, which reads
 * the adapter's user-mode driver version through gdi32!D3DKMTOpenAdapterFromLuid
 * / D3DKMTQueryAdapterInfo / D3DKMTCloseAdapter - all three resolved at run time,
 * so only the declarations and the structure layouts matter. Field names and
 * order mirror the Windows SDK's (D3DKMT_QUERYADAPTERINFO carries the size next
 * to the type, which is what an incorrect first probe here could not
 * distinguish). KMTQAITYPE_UMD_DRIVER_VERSION is pinned by
 * H:/leonida/kmthk_probe.c against this machine's RTX 3080, not from memory.
 */
#ifndef LEONIDA_D3DKMTHK_H
#define LEONIDA_D3DKMTHK_H
#include <windows.h>

typedef int D3DKMT_HANDLE;

typedef enum _KMTQAITYPE {
    KMTQAITYPE_UMDRIVERNAME = 0,
    KMTQAITYPE_UMDRIVERPRIVATE = 1,
    KMTQAITYPE_OPENARGUMENTS = 2,
    KMTQAITYPE_DIRTY = 3,
    KMTQAITYPE_CPDRIVERNAME = 4,
    KMTQAITYPE_QUERYSEGMENT = 5,
    KMTQAITYPE_QUERYSEGMENT_COUNT = 6,
    KMTQAITYPE_UMDRIVERPASSIVE = 7,
    KMTQAITYPE_KBDFOFFSET = 8,
    KMTQAITYPE_NATIVE_UEFI = 9,
    KMTQAITYPE_UMD_DRIVER_VERSION = 10
} KMTQAITYPE;

typedef struct _D3DKMT_OPENADAPTERFROMLUID {
    LUID AdapterLuid;
    D3DKMT_HANDLE hAdapter;
} D3DKMT_OPENADAPTERFROMLUID;

typedef struct _D3DKMT_UMD_DRIVER_VERSION {
    LARGE_INTEGER DriverVersion;
} D3DKMT_UMD_DRIVER_VERSION;

typedef struct _D3DKMT_QUERYADAPTERINFO {
    D3DKMT_HANDLE hAdapter;
    KMTQAITYPE Type;
    UINT PrivateDriverDataSize;
    VOID *pPrivateDriverData;
} D3DKMT_QUERYADAPTERINFO;

typedef struct _D3DKMT_CLOSEADAPTER {
    D3DKMT_HANDLE hAdapter;
} D3DKMT_CLOSEADAPTER;

typedef int NTSTATUS_D3DKMT;

NTSTATUS_D3DKMT WINAPI D3DKMTOpenAdapterFromLuid(D3DKMT_OPENADAPTERFROMLUID *);
NTSTATUS_D3DKMT WINAPI D3DKMTQueryAdapterInfo(const D3DKMT_QUERYADAPTERINFO *);
NTSTATUS_D3DKMT WINAPI D3DKMTCloseAdapter(const D3DKMT_CLOSEADAPTER *);

#endif
