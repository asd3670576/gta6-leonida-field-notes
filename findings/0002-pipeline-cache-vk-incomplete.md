finding: with 16 worker threads and a multi-gigabyte pipeline cache, all four
attempts of the pipeline-cache snapshot loop come back `VK_INCOMPLETE`, so a
periodic save is lost on NVIDIA.

Where: `runtime/test/pipeline_cache_snapshot.h` (the 4-attempt loop) as reached
from `runtime/test/vk_pipeline_check.cpp:935` at `4eb6155d`, reported through
the `"%s pipeline cache save to %s failed: %s"` handler at
`vk_pipeline_check.cpp:943`.

Measured here: Windows 10 19045, RTX 3080 20 GB, driver 610.88, Vulkan 1.4.341,
`vk_pipeline_check.exe` from the `runtime-windows` CI artifact built at
`4eb6155d`, corpus = 26,503 modules, `--jobs 16`:

```
periodic pipeline cache save to H:\leonida\out\pipeline_cache.bin failed:
vkGetPipelineCacheData returned VK_INCOMPLETE
```

That message is the loop's final throw, so the size query plus four reads all
failed on an exact-size buffer while 16 threads kept appending pipelines to a
cache that was about 2.7 GB at the time. One such loss was logged during the
run so far; the cache file itself kept growing, so the failure is intermittent
and scales with cache size and thread count.

Why it matters: the periodic save exists precisely so that a 3-10 hour corpus run
can be interrupted without losing the cache. On the biggest caches - which are
the machines that need those runs - it is the one save most likely to fail.

Status upstream: this is already fixed on current main. `8d34751d`
(PR #9722) changes the loop to read into `size + size >> (4 - attempt)`, i.e.
1/16 slack on the first attempt, doubling to 1/2 on the fourth. Both successor
CI artifacts we downloaded (`2e471574` and `ff8ce388`) contain that fix, and
`4eb6155d` does not. Reported here so the empirical case for #9722 is not lost
with the deleted tracker: it was not only a theoretical race, it fired on real
hardware at 16 jobs.

Needs: nothing further - second verification only, no game data attached.
