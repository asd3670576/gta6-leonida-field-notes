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

### Why the older artifact fails, in code

`4eb6155d` is 2,273 commits behind `ff8ce388`, and every fix that this dry run
depends on postdates it (verified with `git merge-base --is-ancestor`):

- the executable-TLS series - `b7a3fed2` (give a `/GA` executable its own TLS at
  index 0), `a2542ccd`, `66a7dbc1`, `b2902830`, `4710549a`, `e0816d6a` - is all
  after it, which is exactly what the "only one manually mapped module may use
  static TLS at a time" refusal is about; `docs/retail_boot_chain.md` records the
  same shape as its stop 4
- `git show 4eb6155d:runtime/src/main.cpp` accepts only
  `--dry-run / --init / --run / --trace-d3d12 / --game-dir / --overlay`: no
  `--trace`, no `--mods`, no `--archetype-lookup`, no `--view-mode-getter`
- `git show 4eb6155d:runtime/shims/d3d12_vulkan_device.cpp` contains **no
  pipeline-cache code at all** - the cache seeding arrived with `a02d5486`
  (PR #4559), which is not an ancestor of `4eb6155d`. So an artifact of that age
  silently ignores a multi-gigabyte `pipeline_cache.bin` even if it is placed
  correctly
- `runtime/shims/` at that commit has no `acphal.cpp`, `xapu_chad.cpp` or
  `xg_xs.cpp`, which is why the unimplemented count differs so much between the
  two runs above

Practical rule: **use the newest `runtime-windows` artifact, and check its
`head_sha`** before concluding anything from a failure. The artifact's own commit
is one API call away (`/actions/runs/<id>` → `head_sha`).

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

## `--init` on the same images: reproduced, clean

```
gta6rt.exe --init "<package>\game_scarlett_master.exe" --game-dir <package> --overlay <scratch> --trace <file>
exit=0, "5 module(s) initialised"
```

The `--trace` file is exactly 15 records, matching what
`docs/runtime_imports.md:182-185` describes on Windows 11 - here on Windows 10
19045, with the executable that came in the package:

| seq | kind | detail |
|---:|---|---|
| 2-6 | `map` | `XboxBvhBuilder.dll` at its preferred base, the three other package DLLs relocated, `game_scarlett_master.exe` at `0x140000000` (`0xb06d000`) |
| 7-10 | `dllmain` | all four package DLLs, `result: 1` |
| 11-12 | `tls_callback` | `game_scarlett_master.exe+0x55dd4f4` and `+0x55e2ebc`, `reason: 1` (attach) |
| 13 | `exit` | `code: 0` |
| 14-15 | `tls_callback` | same two callbacks, `reason: 0` (detach) |

No `exception`, no `error`, no `unimplemented_call` - so on this machine too,
none of the 11 unimplemented imports is touched by the TLS callbacks or the
`DllMain`s. The raw trace is kept in
[`../data/init_trace_2e471574.jsonl`](../data/init_trace_2e471574.jsonl).

What is still unmeasured by anybody: `--run`. The doc says so itself
(`:187-190`), and it is the only step left after the four above.
