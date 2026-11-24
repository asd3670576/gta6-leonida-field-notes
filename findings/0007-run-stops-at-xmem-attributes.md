finding: on plain `main`, `gta6rt --run` now reaches the retail executable's
entry point and stops at the console memory-attribute wall - and the wall is an
assert followed by a null dereference, not a missing shader or a GPU problem.

Where: measured at `ff8ce388` ("Leonida Continued" main), Windows 10 19045 x64,
RTX 3080 20 GB, driver 610.88, using the project's own `runtime-windows` CI
artifact (`gta6rt.exe` 5,396,992 bytes,
SHA-256 `770B3ADB3AE0EE8FB45FD015C7BABF20101882F1EC274D09F54C6F580EC86184`):

```
gta6rt.exe --run "<package>\game_scarlett_master.exe" --game-dir <package> --overlay <writable> --trace <file>
```

The import surface is complete except one DirectStorage name
([0004](0004-retail-dry-run-11-unimplemented.md) has the table), mapping and
`initialise()` are clean, and then the first thing the entry point does is ask
for console memory:

| seq | api | attributes | size | caller |
|---:|---|---|---:|---|
| 13 | `XMemVirtualAlloc` | `0x21` | 25,769,803,776 (24 GiB) | `exe+0x1e1d00f` |
| 14 | `XMemVirtualAlloc` | `0x3` | 25,769,803,776 (24 GiB) | `exe+0x1e1d03e` |
| 15 | `XMemVirtualAlloc` | `0x183` | 1,228,931,072 | `exe+0x1e1d186` |
| 16 | `XMemVirtualAlloc` | `0x283` | 2,305,818,624 | `exe+0x1e1d4db` |
| 17 | `XMemVirtualAlloc` | `0x181` | 20,971,520 | `exe+0x5ba6c35` |

Every one of those attribute words is refused by the shim (the
`xmem_attributes` trace event exists exactly to record that - see
`docs/retail_boot_chain.md`, whose stop 2 was measured the same way, and commit
`dfcc046b` "all 23 XMemVirtualAlloc sites pass an attribute word the shim
refuses"). The title then asserts:

```
seq 18  int3 (0x80000003) at game_scarlett_master.exe+0x5925915
        stack: +0x5925915 +0x5925831 +0x2240e95 +0x81b253 +0x53ec04f +0x53ebf3a
               +0x661f0 +0x1d109c9 +0x5a91c0d +0x56a1e5a  <- entry +0x56a1ec8
               host:gta6rt.exe+0x15da4b host:KERNEL32.DLL+0x17614 host:ntdll.dll+0x526b1
```

and `LEONIDA_SKIP_INT3=1` shows what the assert is guarding:

```
seq 18  int3_skipped at game_scarlett_master.exe+0x5925915
seq 19  exception 0xc0000005 read of 0x0 at game_scarlett_master.exe+0x5925903
        (same stack, one instruction later)
```

So the assert is not defensive noise: stepping over it walks straight into a
null dereference, because the allocation the title asked for never happened.
That makes stop 2 a single narrow question - what do those attribute words
request, and can the shim honour them - rather than a long list of unknowns.

What this run does **not** show: the GPU is untouched. There is no `[rt] d3d12:`
line at all, `nvidia-smi` stayed at 8 % utilisation / 1.3 GB used for the whole
10 s the process lived (sampled every 10 s, `../data/gpu_run_103228.csv`), and
the runtime never printed `loaded %zu bytes from pipeline_cache.bin`. So neither
the Vulkan device, nor the 26,503-module SPIR-V corpus, nor the 3.04 GB warm
pipeline cache have been exercised yet. Every shader-side number in this
repository is still a translation/validation result, not a rendering one.

Also measured in passing, and worth correcting in the docs:

| build | `game_scarlett_master.exe` shim / host / module / unimplemented |
|---|---|
| docs at `1cc6e3c1` | 53 / 432 / 72 / 30 |
| artifact `2e471574` | 82 / 422 / 72 / 11 |
| artifact `ff8ce388` | 93 / 421 / 72 / **1** (`XCRDAPI.dll!DStorageGetFactory`) |

`docs/runtime_imports.md:9` still states that the executable is not part of the
package and `:147` still shows 30; our 1.0.2.1 package ships
`game_scarlett_master.exe` with the SHA-256 that page already publishes, so both
lines can be updated from a normal user's copy.

One host-side trap while doing this: `--trace` refuses a path that already
exists (`runtime/src/main.cpp:171-175`), and on this machine PowerShell 5.1's
`Start-Process` cannot launch anything at all because the environment holds both
`NO_PROXY` and `no_proxy` ("Item has already been added. Key in dictionary"), so
the launch has to go through a batch file or `System.Diagnostics.Process`.

Needs: one game copy plus the executable; no game data attached here (names,
byte counts and the tool's own trace records only).
