# Findings

Each file is one report, written in the form we would have posted upstream
(`finding:` first line, then `Where / Why it matters / Suggest / Needs / Measured`).
The upstream tracker where these were first reported was deleted on 2026-11-24,
so they are kept here.

| file | finding |
| --- | --- |
| [`0001-incomplete-copy.md`](0001-incomplete-copy.md) | an incomplete 1.0.2.1 copy is reported only as "This doesn't look like a supported version of the game", never as a partial match |
| [`0002-pipeline-cache-vk-incomplete.md`](0002-pipeline-cache-vk-incomplete.md) | the periodic pipeline-cache save fails with `VK_INCOMPLETE` on NVIDIA driver 610.88 |
| [`0003-wmi-adapter-ram.md`](0003-wmi-adapter-ram.md) | `Win32_VideoController.AdapterRAM` caps at 4 GiB, so a 20 GB card reads as 4 GB |
