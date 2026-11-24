# Which D3D12 runtime can Windows 10 19045.3324 take, and what shader model does each give?
# See ag_probe.cpp for why this matters (XCL needs SM 6.6; it can only reach Agility through
# ID3D12SDKConfiguration1::CreateDeviceFactory, which this OS build does not have).
# Here we test the *classic* route: D3D12SDKVersion + D3D12SDKPath exports in the host exe and
# a D3D12\ folder next to it - with today's Agility (1.620.2) and with an older one.
$ErrorActionPreference = 'Continue'
$Proxy = 'http://127.0.0.1:7897'
$envbin = 'C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt'
$env:PATH = "$envbin\Library\bin;$envbin\Library\x86_64-w64-mingw32\bin;$envbin\bin;$env:PATH"
$run = 'H:\leonida\agprobe_r'

# --- get an older Agility NuGet (x64 D3D12Core.dll) -----------------------------------------
$oldDir = 'H:\leonida\agility_old'
$oldVer = ''
foreach ($v in @('1.610.2', '1.610.0', '1.611.1', '1.612.1')) {
    $nupkg = "H:\leonida\agility_$v.zip"
    $url = "https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.d3d12/$v/microsoft.direct3d.d3d12.$v.nupkg"
    try {
        if (-not (Test-Path $nupkg)) { Invoke-WebRequest -Uri $url -OutFile $nupkg -Proxy $Proxy -UseBasicParsing }
        if ((Get-Item $nupkg).Length -lt 1000000) { continue }
        Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive -Path $nupkg -DestinationPath $oldDir -Force
        if (Test-Path "$oldDir\build\native\bin\x64\D3D12Core.dll") { $oldVer = $v; break }
    } catch { Write-Output ("download $v failed: " + $_.Exception.Message) }
}
Write-Output ("older Agility used: " + $(if ($oldVer) { $oldVer } else { 'NONE' }))
$oldSdk = if ($oldVer) { [int](($oldVer -split '\.')[1]) } else { 0 }
Write-Output ("its D3D12SDKVersion number would be $oldSdk")

# --- build the three probe executables -------------------------------------------------------
New-Item -ItemType Directory -Force -Path $run | Out-Null
Remove-Item "$run\ag_*.exe", "$run\D3D12" -Recurse -Force -ErrorAction SilentlyContinue
Set-Location 'H:\leonida'
& g++.exe -std=gnu++17 -D_WIN32_WINNT=0x0A00 -DNO_AGILITY_EXPORTS -o "$run\ag_base.exe" ag_probe.cpp -luuid 2>&1 | Select-Object -First 5
& g++.exe -std=gnu++17 -D_WIN32_WINNT=0x0A00 -DAGILITY_VERSION=620 -o "$run\ag_1620.exe" ag_probe.cpp -luuid 2>&1 | Select-Object -First 5
if ($oldSdk) { & g++.exe -std=gnu++17 -D_WIN32_WINNT=0x0A00 "-DAGILITY_VERSION=$oldSdk" -o "$run\ag_old.exe" ag_probe.cpp -luuid 2>&1 | Select-Object -First 5 }

function Show($name, $exe) {
    Write-Output "--- $name ---"
    if (-not (Test-Path "$run\$exe")) { Write-Output "  (not built)"; return }
    Set-Location $run
    & ".\$exe" 2>&1 | ForEach-Object { '  ' + $_ }
    Write-Output ("  exit=" + $LASTEXITCODE)
}

Set-Location $run
Write-Output ''
Write-Output '================ no D3D12\ folder ================'
Show 'baseline exe, no exports (inbox runtime)' 'ag_base.exe'
Show 'exports 620, no folder present' 'ag_1620.exe'

Write-Output ''
Write-Output '================ D3D12\ = Agility 1.620.2 ================'
Remove-Item "$run\D3D12" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$run\D3D12" | Out-Null
Copy-Item 'H:\leonida\agility\build\native\bin\x64\D3D12Core.dll' "$run\D3D12\" -Force
Show 'baseline exe (folder must be ignored)' 'ag_base.exe'
Show 'exports 620 + folder' 'ag_1620.exe'

if ($oldSdk) {
    Write-Output ''
    Write-Output "================ D3D12\ = Agility $oldVer ================"
    Remove-Item "$run\D3D12" -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path "$run\D3D12" | Out-Null
    Copy-Item "$oldDir\build\native\bin\x64\D3D12Core.dll" "$run\D3D12\" -Force
    Show "exports $oldSdk + folder" 'ag_old.exe'
    Show 'exports 620 + older folder (version mismatch expected)' 'ag_1620.exe'
}
Write-Output 'DONE_AGILITY_MATRIX'
