finding: `Win32_VideoController.AdapterRAM` cannot report more than 4 GiB, so a
20 GB card reads as 4 GB - and the repo's own spec checker moved to a web page
without a test for that case.

Measured here: Windows 10 19045, NVIDIA GeForce RTX 3080 with **20 GB**:

| source | reported memory |
| --- | --- |
| `Win32_VideoController.AdapterRAM` (WMI) | `4293918720` = `0xFFF00000` (4 GiB − 1 MiB); the property is a 32-bit value, so it saturates |
| registry `HardwareInformation.qwMemorySize` | 64-bit, reports the real size |
| `nvidia-smi --query-gpu=memory.total` | 20480 MiB |
| Vulkan `VkPhysicalDeviceMemoryProperties` | 20 GB |

Why it matters: the project asks for 8 GB+ of VRAM on the higher profile, so a
12 / 16 / 20 / 24 GB card - the class that meets it - is the exact population
where a WMI-only reading is wrong. Anyone writing a checker (or a bot that
answers "can my PC run it") should take the size from Vulkan, or from
`qwMemorySize`, and treat `AdapterRAM` as a 4 GiB-capped last resort.

State of the code at `ff8ce388`:

- `tools/pc_checker.py` **no longer exists** - deleted by `5125a01f`
  (2026-11-23, "Remove pc_checker.py and point to web checker", closes #9711),
  together with `tests/test_pc_checker.py`. `README.md:128` now points at the
  browser checker <https://assttro.github.io/can-i-run-leonida/>.
- The last version before deletion already knew about the cap - its own
  docstring at `tools/pc_checker.py:443-444` (as of `5125a01f^`) says
  *"VRAM per adapter from the registry (Win32_VideoController caps at 4 GB)"*,
  preferring `qwMemorySize` and using `AdapterRAM / 2**30` only as a fallback
  (`:481-496`). So the design was right; the fallback is the trap.
- The deleted test file had **no** case above 4 GiB: the only VRAM-related test
  was `test_vram_suffix_ignored`, which parses a name string, not a size.
  Nothing in the repo now pins the >4 GB behaviour, and a browser checker cannot
  read `qwMemorySize` either.

Suggest: whatever checker is authoritative now, state the 4 GiB ceiling in its
output when the value comes from WMI (`">= 4 GB (WMI cannot report more)"`)
rather than printing the truncated number, and keep one regression case for a
>4 GiB adapter.

Status upstream: PR #5112 was open on exactly this when the repository went 404
on 2026-11-24, so both the fix and the report that prompted it disappeared.
This file is the surviving second-verification record: the reading is not a
driver bug, it is the documented 32-bit cap, and the card is genuinely 20 GB.

Measured on: Windows 10 19045 x64, driver 610.88, Python 3.12.14, at `e0816d6af`
(the last commit that still had `pc_checker.py` on our side) and re-checked
against `ff8ce388`. No game data attached.
