# Clean test of the classic Agility selection with the right PE ordinals.
# Why: GNU ld will not parse a .def given as an input file for an EXE ("file format not
# recognized; treating as linker script"), and __declspec(dllexport) alone assigns ordinals
# alphabetically - D3D12SDKPath would take ordinal 1 where the D3D12 runtime expects
# D3D12SDKVersion. So the earlier "1114 for every version" reading is not yet trustworthy.
# Method: dlltool turns the .def into an export object (--output-exp); we link that object
# into the probe and read the export table back with llvm-readelf before running it.
$ErrorActionPreference = 'Continue'
$envbin = 'C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt'
$env:PATH = "$envbin\Library\bin;$envbin\Library\x86_64-w64-mingw32\bin;$envbin\bin;$env:PATH"
$dlltool = "$envbin\Library\bin\dlltool.exe"
if (-not (Test-Path $dlltool)) { $dlltool = "$envbin\Library\x86_64-w64-mingw32\bin\dlltool.exe" }
Write-Output ('dlltool: ' + $dlltool + '  exists=' + (Test-Path $dlltool))
$readelf = 'C:\Users\L.S\AppData\Local\miniforge3\envs\llvm-tools\Library\bin\llvm-readelf.exe'
$run = 'H:\leonida\agprobe_r'
New-Item -ItemType Directory -Force -Path $run | Out-Null
Set-Location 'H:\leonida'

foreach ($sdk in 620, 610) {
    $def = "$run\def_$sdk.def"
    @(
        "LIBRARY agD_$sdk.exe"
        'EXPORTS'
        '  D3D12SDKVersion DATA @1'
        '  D3D12SDKPath DATA @2'
    ) | Set-Content $def -Encoding ascii

    & $dlltool --dllname "agD_$sdk.exe" --input-def $def --output-exp "$run\exp_$sdk.o" 2>&1 | Select-Object -First 3
    Write-Output ("sdk $sdk dlltool_exit=$LASTEXITCODE  exp object exists=" + (Test-Path "$run\exp_$sdk.o"))

    & g++.exe -std=gnu++17 -D_WIN32_WINNT=0x0A00 "-DAGILITY_VERSION=$sdk" -DUSE_DEF_EXPORTS `
        -o "$run\agD_$sdk.exe" ag_probe.cpp "$run\exp_$sdk.o" -luuid 2>&1 | Select-Object -First 6
    if (-not (Test-Path "$run\agD_$sdk.exe")) { Write-Output "sdk $sdk : link failed"; continue }

    Write-Output "--- export table (name / ordinal) ---"
    & $readelf --exports "$run\agD_$sdk.exe" 2>&1 | Select-String -Pattern 'D3D12SDK' | ForEach-Object { $_.Line.Trim() }

    foreach ($with in @('core', 'core+dxil')) {
        Remove-Item "$run\D3D12" -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path "$run\D3D12" | Out-Null
        $src = if ($sdk -eq 620) { 'H:\leonida\agility\build\native\bin\x64\D3D12Core.dll' } else { 'H:\leonida\agility_cache\1.610.2\build\native\bin\x64\D3D12Core.dll' }
        Copy-Item $src "$run\D3D12\D3D12Core.dll" -Force
        if ($with -eq 'core+dxil') { Copy-Item 'H:\leonida\dxc\bin\x64\dxil.dll' "$run\D3D12\dxil.dll" -Force }
        Push-Location $run
        $out = & ".\agD_$sdk.exe" 2>&1 | Out-String
        $code = $LASTEXITCODE
        Pop-Location
        $loaded = if ($out -match 'D3D12Core\.dll\s+(\S+)') { $matches[1] } else { 'none' }
        $sm = if ($out -match 'asking for 6\.6: (\S+)') { $matches[1] } else { '?' }
        $state = if ($out -match 'FAILED err=(\d+)') { 'LoadLibrary err ' + $matches[1] } elseif ($out -match 'CreateDevice = 0x00000000') { 'device ok' } else { 'create failed' }
        Write-Output ("sdk $sdk  D3D12\=$with  $state  SM6.6 -> $sm  D3D12Core from: $loaded  exit=$code")
    }
    Remove-Item "$run\D3D12" -Recurse -Force -ErrorAction SilentlyContinue
    Push-Location $run
    $bare = & ".\agD_$sdk.exe" 2>&1 | Out-String
    Pop-Location
    $bstate = if ($bare -match 'FAILED err=(\d+)') { 'LoadLibrary err ' + $matches[1] } else { 'device ok' }
    Write-Output ("sdk $sdk  no D3D12\ folder  $bstate  (expected: fails, proving the exports are read)")
}
Write-Output 'DONE_DEF_TEST'
