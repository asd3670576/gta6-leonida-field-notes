# Publish the pool-by-pool XCL memory reading as findings/0012, with a provenance header.
$ErrorActionPreference = 'Stop'
$src = 'H:\leonida\field-notes-draft\0009-xcl-memory-model.md'
$dst = 'H:\leonida\field-notes\findings\0012-xcl-memory-model.md'
$body = Get-Content $src -Encoding UTF8
$header = @(
    '# 0012 - XCL memory model: where the bytes actually go',
    '',
    '**Date:** 2026-11-24. Read-only inspection of `ivall/xcl` at `main` as cloned on',
    '2026-11-24 (no build, no run in this document; the measurements it refers to are in',
    '[0009](0009-xcl-run-here-and-memory-patches.md)). Every claim cites a file and line in',
    '`crates/xcl/src/`. Written to answer one question: which of XCL`s memory costs are',
    'configurable, which are duplicated on purpose, and which are never given back.',
    ''
)
$out = $header + $body
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($dst, $out, $enc)
Write-Output ('wrote ' + $dst + '  ' + (Get-Item $dst).Length + ' bytes, ' + $out.Count + ' lines')
