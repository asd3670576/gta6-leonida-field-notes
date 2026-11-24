finding: a GPU-size check that reads `Win32_VideoController.AdapterRAM` cannot
see past 4 GiB, so a 20 GB card is reported as 4 GB.

Where: the PC-spec check in `pc_checker.py` (the GPU-size path that queries WMI).

Measured here: Windows 10 19045, NVIDIA GeForce RTX 3080 with **20 GB**:

| source | reported memory |
| --- | --- |
| `Win32_VideoController.AdapterRAM` (WMI) | `4293918720` = `0xFFF00000` (4 GiB − 1 MiB); the property is a 32-bit value, so it saturates |
| `nvidia-smi --query-gpu=memory.total` | 20480 MiB |
| Vulkan `VkPhysicalDeviceMemoryProperties` | 20 GB |

Why it matters: the project's own advice is "at least 8 GB of VRAM" for the
higher profile, so a 12 / 16 / 20 / 24 GB card - the exact class of card that
meets it - is told it has 4 GB and fails. A reader then either gives up or
downgrades their settings for no reason.

Suggest: take the size from Vulkan (`VkPhysicalDeviceMemoryProperties`, which the
runtime already loads) and use WMI only as a fallback when Vulkan enumeration is
unavailable; note the fallback's cap in the message rather than printing the
truncated number as if it were real.

Status upstream: PR #5112 was open on exactly this when the repository went 404
on 2026-11-24, so the fix and the report that prompted it both disappeared.
This file is the second-verification record for it: the reading is not a bug in
our driver, it is the documented 32-bit cap, and the card is genuinely 20 GB.

Needs: nothing further - no game data attached.
