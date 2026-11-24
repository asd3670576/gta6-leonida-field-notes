# Publish the stop-point decode as findings/0011 with a provenance header.
$ErrorActionPreference = 'Stop'
$src = 'H:\leonida\findings_draft\stop2_guest_decode.md'
$dst = 'H:\leonida\field-notes\findings\0011-the-boot-stop-is-gameinputcreate.md'
$body = Get-Content $src -Encoding UTF8
$header = @(
    '# 0011 - The boot stop is the title asserting on GameInputCreate, not on console memory',
    '',
    '**Date:** 2026-11-24. **Tree:** `ubiquitarianism/leonida` @ `ff8ce388`, with the runtime',
    'built by us under MinGW (0008). **Host:** Windows 10 19045.3324, RTX 3080 20 GB.',
    '',
    'This supersedes the reading in 0007. There the halt was described as a',
    '"console memory-attribute wall"; the allocations it pointed at all succeed, which we',
    'established by instrumenting our own build (xmem.cpp logs every XMemVirtualAlloc result',
    'under `LEONIDA_XMEM_LOG`) and by decoding the guest instructions from the shipped',
    'executable with `port/guest_disasm.py` (PE section table -> RVA -> llvm-mc).'
)
$out = $header + @('') + $body
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($dst, $out, $enc)
Write-Output ('wrote ' + $dst + '  ' + (Get-Item $dst).Length + ' bytes, ' + $out.Count + ' lines')
Write-Output '--- first 6 body lines of the draft, for reference ---'
$body | Select-Object -First 6
