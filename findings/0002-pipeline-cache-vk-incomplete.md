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
can be interrupted without losing the cache - `docs/pipeline_check.md:33`
promises "saved every 10 minutes and at the end, so a stopped run resumes". On
this run that is roughly 45 periodic saves, of which one was lost, and the loss
is the size- and thread-dependent kind: `--jobs 16` (the default is half the
hardware threads, `vk_pipeline_check.cpp:799`) on a 32-thread CPU with a cache
near 3 GB. The tool's own unit test models exactly this and says so -
`runtime/test/pipeline_cache_snapshot_test.cpp:53-72`, "Reading into exactly the
queried size returned VK_INCOMPLETE here on every attempt", with the doubling
growth case expected to reach "the four-attempt error". Our run is that case on
real hardware, at a size the unit test cannot reach.

Status upstream: this is already fixed on current main. `8d34751d`
(PR #9722) changes the loop to read into `size + size >> (4 - attempt)`, i.e.
1/16 slack on the first attempt, doubling to 1/2 on the fourth
(`pipeline_cache_snapshot.h:23` at HEAD). Both successor CI artifacts we
downloaded (`2e471574` and `ff8ce388`) contain that fix, and `4eb6155d` does
not. Reported here so the empirical case for #9722 is not lost with the deleted
tracker: it was not only a theoretical race, it fired on real hardware at
16 jobs and a multi-gigabyte cache.

Not documented anywhere: `docs/pipeline_check.md` and the tool's usage header
(`vk_pipeline_check.cpp:1-47`) never mention `VK_INCOMPLETE` or the retry
expectation - it lives only in code comments and the unit test. A line in the
docs ("a periodic save can fail on a large cache; the run continues and the
final save is the one that matters") would stop people reading one such line as
a corrupted run.

Needs: nothing further - second verification only, no game data attached.
