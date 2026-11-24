finding: `docs/runtime_imports.md` still says the retail executable is not part
of the package and quotes 30 unimplemented imports; a dry run against the
executable **inside** the 1.0.2.1 package now maps all five modules and reports
11, and only audio + DirectStorage names are left.

Where: `docs/runtime_imports.md:9` ("The game executable is not in the package"),
`:129-147` (the RT-5 table, measured at `1cc6e3c1`, Windows 11, MSVC 14.44),
`:153-181` (the seven-DLL breakdown and the "served now" corrections).

Measured here: Windows 10 19045 x64, RTX 3080 20 GB, driver 610.88.
`gta6rt.exe --dry-run` from the successor's `runtime-windows` CI artifact built
at `2e471574`:

```
gta6rt.exe --dry-run "<package>\game_scarlett_master.exe" --game-dir <package> --overlay <scratch>
```

| Image | Base | Size of image | Entry RVA | Shim | Host | Module | Unimplemented |
|---|---|---:|---:|---:|---:|---:|---:|
| `game_scarlett_master.exe` | `0x140000000` | 184,995,840 | `0x56a1ec8` | 82 | 422 | 72 | **11** |
| `XboxBvhBuilder.dll` | `0x180000000` | 909,312 | `0x227cc` | 5 | 52 | 0 | 0 |
| `amd_fidelityfx_loader_xbox.dll` | relocated | 32,768 | `0x18d0` | 6 | 16 | 0 | 0 |
| `libHttpClient.GDK.dll` | relocated | 999,424 | `0x11f0` | 28 | 170 | 0 | 0 |
| `Bink2Scarlett.dll` | relocated | 278,528 | `0x2ac1c` | 8 | 52 | 0 | 0 |

```
5 module(s) mapped, 11 unimplemented import(s)
unimplemented by return policy: hresult=0 other=11
```

The 11, in full — nothing in graphics, nothing in the file system:

| DLL | Count | Names |
|---|---:|---|
| `chad.dll` | 5 | `XDspActivate`, `XDspConnectWithMaximumStreamLimit`, `XDspDeactivate`, `XDspDisconnect`, `XDspSubmitCommand` |
| `xapu.dll` | 5 | `XApuConnect`, `XApuDequeueResult`, `XApuDisconnect`, `XApuEnqueueCommand`, `XApuGetResultCount` |
| `XCRDAPI.dll` | 1 | `DStorageGetFactory` |

Compared with the doc's table, the executable's shim count went 53 → 82 and the
unimplemented count 30 → 11: all seven `xmem.dll` names, both `xg_xs.dll` names,
`d3d12_xs.dll!D3D12ConfigureVirtualMemoryX` and all nine `AcpHal.dll` names now
bind. `xmem.dll`, `d3d12_xs.dll` and `xg_xs.dll` therefore no longer belong in
the "no model yet" list, and `AcpHal.dll` - the largest single group at the time
- is served.

One loader note printed on the same run, worth knowing because it is silent
about how much it does:

```
[rt] loader: game_scarlett_master.exe: 53246 index-0 TLS reads (gs:[58h]) now
read its own TLS (TlsSlots[2]); its module TLS index is 5
```

Second finding in the same run - **runtime artifacts age badly**: the same
command with the artifact built at `4eb6155d` (upstream main on 2026-11-23, one
day older) does not map anything:

```
error: XboxBvhBuilder.dll: only one manually mapped module may use static TLS at a time
```

exit 1, no per-image report. Anyone reusing a saved `runtime-windows` artifact
from before the multi-module static-TLS work hits this and may conclude the
package or the executable is broken. Worth a line in the artifact README, or a
version stamp in the error.

Suggest: update the RT-5 table from a package that ships the executable (the
1.0.2.1 copy we hold does, `game_scarlett_master.exe`,
SHA-256 `e95020b2fa4a721db3df59fdecf75621730ac559d8835252f6c3b658d5a08993`,
matching the digest already published in the doc), and restate which of the
seven DLLs now bind. Nothing in the graphics path is unimplemented, which
changes what a first-frame attempt depends on: audio (`chad`/`xapu`) and
DirectStorage (`DStorageGetFactory`) only - and by the doc's own policy an
unimplemented import stops the run only if the title calls it.

Needs: no game data attached; the numbers above are the tool's own report.
Measured on `2e471574`; a re-measure at `ff8ce388` is queued, which additionally
carries `f35d19cb` (the retail exe imports `SetThreadGroupAffinity`).
