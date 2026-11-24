finding: `docs/pipeline_check.md` says crash isolation is POSIX only, but the
same commit that added it gave `vk_pipeline_check` a Windows child-process path.

Where: `docs/pipeline_check.md:42` (the option table cell for `--isolate`,
"POSIX only") against the same page's `:383-384` ("child processes on native
Windows and POSIX") and the code: `runtime/test/vk_pipeline_check.cpp:702`
(`CreateProcessW` child path, with `#ifdef _WIN32` at `:601/:612/:626` and the
POSIX `fork`/`waitpid` path at `:736/:754`).

Both lines come from `8d34751d` (PR #9722), so the table cell is stale rather
than aspirational. Verified at `ff8ce388`.

Why it matters: `--isolate` is the mode that survives a driver crash mid-corpus
(a crashed batch is bisected to the module and reported as
`MODULE CRASH <name> (<stage>, driver crashed: SIGFPE)`). A Windows user - which
is most of the NVIDIA/Intel audience - reading the table will not try it, and
will instead lose the whole run to one bad compile.

Suggest: change the cell to "Windows and POSIX", and note the two refusals in
the same row: `--isolate` is refused with `--stats`
(`vk_pipeline_check.cpp:876-877`), and there is no timeout, so a hung compile
still hangs (`docs/pipeline_check.md:408`).

Needs: no game data; a one-line docs patch.
