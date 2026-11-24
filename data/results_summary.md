# Leonida (GTA VI Xbox Series recompiler) - measurements from one PC

Machine: Windows 10 Pro for Workstations 19045 x64, AMD Ryzen 9 5950X (16C/32T), 64 GB RAM, NVIDIA GeForce RTX 3080 **20 GB**, driver 610.88, Vulkan 1.4.341, subgroup 32-32. Python 3.12.14, LLVM 23.1.6 (`llvm-mc` gfx1013), SPIRV-Tools 2026.4.

## shader_carve (shaders.rpf -> DXBC)
- 26503 shaders carved, 1 candidate rejected; stages {'vs': 2236, 'ms': 9282, 'ps': 12101, 'gs': 195, 'cs': 2689}; shader models {'6.6': 26503}

## fssm_unpack
- 26503 FSSM blobs, problems {}
- size min 578, median 10479, max 493467, total 412 MiB


## rdna2spirv (DXBC -> SPIR-V, 16 shards, --wave64-emulate)
- 26503 translated, 26503 pass spirv-val, merged 26503 entries
- wave64 VS/PS/GS on 32-wide subgroups: tier A 5059, tier B 101, tier C 8245

## vk_pipeline_check slice (1500 modules, --jobs 8)
- index: 26503 shaders
- cs: 2 modules ok / 0 failed; pipelines 2 ok / 0 failed / 0 skipped; wave32 2 ok, wave64 0 ok (0 without required subgroup size); mean 0.053s, slowest !im_CS_DepthCopy_9c3b492b_Wrapped 0.08s
- ms: 658 modules ok / 0 failed; pipelines 658 ok / 0 failed / 0 skipped; wave32 658 ok, wave64 0 ok (0 without required subgroup size); mean 1.614s, slowest !MS_VS_Transform_e74ae427_Wrapped~2 41.34s
- ps: 819 modules ok / 0 failed; pipelines 819 ok / 0 failed / 0 skipped; wave32 299 ok, wave64 520 ok (520 without required subgroup size); mean 4.505s, slowest !PS_PuddleDetect_cf03bbb3_Wrapped~15 45.64s
- vs: 21 modules ok / 0 failed; pipelines 21 ok / 0 failed / 0 skipped; wave32 0 ok, wave64 21 ok (21 without required subgroup size); mean 0.107s, slowest !VS_OctaWindFire_e6901d4b_Wrapped 1.84s
- wall time: 599.9s on 8 threads
pipeline cache: 262215635 bytes -> H:\leonida\out\pipeline_cache_slice.bin

- pipeline cache: 262215635 bytes -> H:\leonida\out\pipeline_cache_slice.bin

- last progress line: 1500 pipelines, 600s elapsed

## vk_pipeline_check full corpus
- index: 26503 shaders
- modules recorded in stats file: 19527
- last progress line: 19500 pipelines, 26176s elapsed
- periodic pipeline cache save failed 1x: vkGetPipelineCacheData
- 'still compiling' warnings: 592

## package completeness
- manifest 108 entries: 68 present with matching size, None size mismatches, 40 absent
- restored 40 of the absent entries from the package's own torrent (33390534 bytes), all matching manifest size + SHA-256, then re-verified in place
- `make_game.py --check`: 08:38:00  check: Xbox Series package 1.0.2.1, 108 files
- `make_game.py --check`: 08:38:00  check: all files present. Executable found.
