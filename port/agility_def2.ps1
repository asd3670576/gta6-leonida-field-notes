# Get the two exports out at ordinals 1 and 2 with MinGW's dlltool, then re-run the Agility
# test. Proof that ordinals were the problem (from the probe's own export dump):
#   self export: D3D12SDKPath     ordinal=1  value=0x5c3231443344      <- the string "D3D12\"
#   self export: D3D12SDKVersion  ordinal=2  value=0x314433440000026c  <- 0x26c = 620
# i.e. __declspec(dllexport) sorted them alphabetically, and the D3D12 runtime reads version
# from ordinal 1. dlltool lives in Library\x86_64-w64-mingw32\bin, not Library\bin.
$ErrorActionPreference = 'Continue'
$envbin = 'C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt'
$env:PATH = "$envbin\Library\bin;$envbin\Library\x86_64-w64-mingw32\bin;$envbin\bin;$env:PATH"
$dlltool = "$envbin\Library\x86_64-w64-mingw32\bin\dlltool.exe"
$run = 'H:\leonida\agprobe_r'
Set-Location 'H:\leonida'

$syntaxes = [ordered]@{
    A = @('LIBRARY agD.exe', 'EXPORTS', '  D3D12SDKVersion DATA @1', '  D3D12SDKPath DATA @2')
    B = @('LIBRARY agD.exe', 'EXPORTS', '  D3D12SDKVersion @1 DATA', '  D3D12SDKPath @2 DATA')
    C = @('LIBRARY agD.exe', 'EXPORTS', '  D3D12SDKVersion @1', '  D3D12SDKPath @2')
}
$good = ''
foreach ($k in $syntaxes.Keys) {
    $def = "$run\def_$k.def"
    $syntaxes[$k] | Set-Content $def -Encoding ascii
    $err = "$run\dlltool_$k.txt"
    Remove-Item "$run\exp_$k.o" -Force -ErrorAction SilentlyContinue
    & $dlltool --dllname agD_$k.exe --input-def $def --output-exp "$run\exp_$k.o" 2> $err | Out-Null
    $code = $LASTEXITCODE
    $made = Test-Path "$run\exp_$k.o"
    $msg = (Get-Content $err -ErrorAction SilentlyContinue | Select-Object -First 1)
    Write-Output ("syntax $k : exit=$code object=$made  " + $msg)
    if ($code -eq 0 -and $made) { $good = $k; break }
}
if (-not $good) { Write-Output 'no dlltool syntax worked'; exit 1 }
Write-Output ("using syntax $good")

& g++.exe -std=gnu++17 -D_WIN32_WINNT=0x0A00 -DAGILITY_VERSION=620 -DUSE_DEF_EXPORTS `
    -o "$run\agD.exe" ag_probe.cpp "$run\exp_$good.o" -luuid 2>&1 | Select-Object -First 8
if (-not (Test-Path "$run\agD.exe")) { Write-Output 'link failed'; exit 1 }

Remove-Item "$run\D3D12" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$run\D3D12" | Out-Null
foreach ($v in @('H:\leonida\agility\build\native\bin\x64\D3D12Core.dll',
                 'H:\leonida\agility_cache\1.610.2\build\native\bin\x64\D3D12Core.dll',
                 'H:\leonida\agility_cache\1.608.2\build\native\bin\x64\D3D12Core.dll')) {
    Copy-Item $v "$run\D3D12\D3D12Core.dll" -Force
    Copy-Item 'H:\leonida\dxc\bin\x64\dxil.dll' "$run\D3D12\dxil.dll" -Force
    Push-Location $run
    $out = & '.\agD.exe' 2>&1 | Out-String
    $code = $LASTEXITCODE
    Pop-Location
    $loaded = if ($out -match 'D3D12Core\.dll\s+(\S+)') { $matches[1] } else { 'none' }
    $sm = if ($out -match 'asking for 6\.6: (\S+)') { $matches[1] } else { '?' }
    $state = if ($out -match 'FAILED err=(\d+)') { 'LoadLibrary err ' + $matches[1] } elseif ($out -match 'CreateDevice = 0x00000000') { 'device ok' } else { 'create failed' }
    $dllver = (Get-Item "$run\D3D12\D3D12Core.dll").VersionInfo.FileVersion
    Write-Output ("Agility $dllver : $state  SM6.6 -> $sm  core from $loaded  exit=$code")
    foreach ($l in ($out -split "`n")) { if ($l -match 'self export') { Write-Output ('   ' + $l.Trim()) } }
}
Write-Output 'DONE_DEF2'
