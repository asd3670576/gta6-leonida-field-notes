finding: an incomplete 1.0.2.1 copy is reported only as "This doesn't look like
a supported version of the game", never as a partial match.

Where (verified at `ff8ce388`, "Leonida Continued" main, 2026-11-24):

- `make_game.py:318` — `PROBES = ("MicrosoftGame.Config", "Catalog000.bin", "appdata0.rpf")`
- `make_game.py:324` — only probes that are *present* are compared, so an absent
  probe silently fails the match
- `make_game.py:348-361` — `load_version()` returns None and the run dies with

  ```
  This doesn't look like a supported version of the game. Point --game at the
  folder that holds MicrosoftGame.Config and the .rpf archives.
  Supported:
  ...
  ```

  the per-file manifest loop never being reached
- `make_game.py:508` — folder discovery additionally requires
  `MicrosoftGame.Config` in the folder, so `--find` reports **no copy at all**
  rather than an incomplete one

Why it matters: a copy holding 68 of the 108 `game/xbox-1.0.2.1.json` entries,
every present one matching its manifest size exactly (0 size mismatches), is
rejected as "unsupported" because the three probe files happen to be among the
missing ones. The message names only those three probes, so a reader cannot tell
"wrong game" from "download stopped early" - and the second case is fixed by
fetching 33 MB, not by buying a different build.

Measured here: our copy was missing 40 manifest entries totalling 33,390,534
bytes (largest 6,642,192), including **all three probes** and the 16 DLLs the
runtime maps. After restoring them (each verified by size + SHA-256 against the
repo manifest, then hashed again in place), the same command reports:

```
08:38:00  check: Xbox Series package 1.0.2.1, 108 files
08:38:00  check: all files present. Executable found.
```

Exact strings, so the report can be checked without a game copy
(`make_game.py`, `ff8ce388`; `fail()` prefixes them with `ERROR: `, `:112`):

- `:326` `"No version probe files are listed in the manifest."`
- `:334` `f"Missing {name}."` ← what our copy hit, three times
- `:341` `f"{name} is not a regular file."`
- `:343` `f"Wrong size for {name} ({info.st_size} bytes, expected {expected_size})."`
- `:358` each candidate renders as `f"  {version['title']} {version['version']}\n    " + mismatches`
- `:1062-1075` the `check()` body that *would* name every missing file
  (`print(f"  missing  {rel}")`, `:1067`) and would print
  `check: all files present. Executable found.` - unreachable here, because
  `load_version()` already failed

Where a fix would be tested: `tests/test_make_game_preflight.py:136-143` and
`:151-171` already assert the per-version probe mismatch lines, and
`tests/test_make_game_container.py:129-139` covers the container notes - a
synthetic folder with half a manifest present fits the same pattern.

Suggest: when no version matches but at least half the manifest entries match by
name and size, print `N of M manifest files present with matching sizes` plus
the missing names, and say the copy looks **incomplete** rather than
unsupported. Keep the current wording when the probes match but the sizes do
not, which is the genuine "wrong version" case.

Needs: a game copy to reproduce end-to-end; the diagnostic itself is pure Python
and testable with synthetic manifests and a synthetic folder, the way #339's
tests do. No game data attached - only names and byte counts that already appear
in `game/xbox-1.0.2.1.json`.

Measured on: Windows 10 19045 x64, Python 3.12.14, `make_game.py` at
`e0816d6af` (the deleted upstream tracker) and re-checked at `ff8ce388`.
