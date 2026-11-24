#!/usr/bin/env python3
"""Put the two Agility-selection exports at the ordinals the D3D12 runtime expects:
D3D12SDKVersion at ordinal 1, D3D12SDKPath at ordinal 2.

Why a script does this: the runtime reads these exports BY ORDINAL, but GNU ld assigns PE
ordinals alphabetically for __declspec(dllexport), which yields D3D12SDKPath at 1 and
D3D12SDKVersion at 2 (proved by ag_probe.cpp printing its own export table). MinGW's
dlltool refused to emit both entries from a .def ("Syntax error in def file", exit status 0,
one export written), so we rewrite the export directory in the linked image instead.

Fix = swap the two AddressOfFunctions entries AND the two matching AddressOfNameOrdinals
entries, so ordinal 1 points at the version value and every name still resolves correctly.
"""
import struct
import sys


def patch(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    if data[:2] != b'MZ':
        sys.exit('not a PE: ' + path)
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        sys.exit('no PE signature: ' + path)
    opt = pe + 24
    if struct.unpack_from('<H', data, opt)[0] != 0x20B:
        sys.exit('not PE32+: ' + path)
    exp_rva = struct.unpack_from('<I', data, opt + 112)[0]        # data directory 0 = export
    if exp_rva == 0:
        sys.exit('no export directory (build with __declspec(dllexport) first): ' + path)

    nsec = struct.unpack_from('<H', data, pe + 6)[0]
    sizeopt = struct.unpack_from('<H', data, pe + 20)[0]
    secoff = pe + 24 + sizeopt
    secs = []
    for i in range(nsec):
        e = secoff + 40 * i
        # Section header: name[8], VirtualSize(+8), VirtualAddress(+12), SizeOfRawData(+16),
        # PointerToRawData(+20).  Getting these offsets right matters: matching on the wrong
        # span silently picks the wrong section and turns an RVA into junk.
        vsz, va, rawsize, praw = struct.unpack_from('<IIII', data, e + 8)
        if praw == 0 or rawsize == 0:
            continue                      # .bss and friends: nothing on disk to read
        secs.append((va, rawsize, praw))

    def off(rva):
        # No slack here: a slack of even one page lets .bss (RVA 0xe000, no file data) shadow
        # .edata (0xf000) and turns every RVA into junk read out of .text.
        for va, rawsize, praw in secs:
            if va <= rva < va + rawsize:
                return praw + (rva - va)
        sys.exit('RVA %#x outside every file-backed section: %s' % (rva, path))

    e = off(exp_rva)
    base = struct.unpack_from('<I', data, e + 16)[0]
    nfuncs = struct.unpack_from('<I', data, e + 20)[0]
    nnames = struct.unpack_from('<I', data, e + 24)[0]
    af = off(struct.unpack_from('<I', data, e + 28)[0])
    an = off(struct.unpack_from('<I', data, e + 32)[0])
    ao = off(struct.unpack_from('<I', data, e + 36)[0])
    if base != 1 or nfuncs < 2:
        sys.exit('unexpected export layout (base=%d funcs=%d): %s' % (base, nfuncs, path))

    idx = {}
    for i in range(nnames):
        nrva = struct.unpack_from('<I', data, an + 4 * i)[0]
        noff = off(nrva)
        idx[data[noff:data.index(b'\0', noff)].decode('ascii')] = i
    if 'D3D12SDKVersion' not in idx or 'D3D12SDKPath' not in idx:
        sys.exit('both exports must already be present, found %s: %s' % (sorted(idx), path))
    iv, ip = idx['D3D12SDKVersion'], idx['D3D12SDKPath']
    ov = struct.unpack_from('<H', data, ao + 2 * iv)[0]           # function index behind the name
    op = struct.unpack_from('<H', data, ao + 2 * ip)[0]
    if ov == 0 and op == 1:
        print('already correct (%s): version@%d path@%d' % (path, base + 0, base + 1))
        return
    rv = struct.unpack_from('<I', data, af + 4 * ov)[0]
    rp = struct.unpack_from('<I', data, af + 4 * op)[0]
    struct.pack_into('<I', data, af + 4 * 0, rv)                  # ordinal 1 -> the version
    struct.pack_into('<I', data, af + 4 * 1, rp)                  # ordinal 2 -> the path string
    struct.pack_into('<H', data, ao + 2 * iv, 0)
    struct.pack_into('<H', data, ao + 2 * ip, 1)
    with open(path, 'wb') as f:
        f.write(data)
    print('patched %s: version -> ordinal %d (RVA %#x), path -> ordinal %d (RVA %#x)'
          % (path, base, rv, base + 1, rp))


if __name__ == '__main__':
    for p in sys.argv[1:]:
        patch(p)
