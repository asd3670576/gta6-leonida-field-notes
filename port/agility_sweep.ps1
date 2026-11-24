# Can Windows 10 19045.3324 load ANY Agility SDK that gives Shader Model 6.6, through the
# pre-KB5029331 mechanism (D3D12SDKVersion + D3D12SDKPath exports in the host exe)?
# 620 and 610 were already measured to fail (1114 DLL_INIT_FAILED). The OS validates the
# requested version against a per-build table, so the older releases are worth sweeping:
# SM 6.6 needs Agility >= 1.600, and every version that is both >= 600 and accepted by the
# table is a way to run XCL's recompiler on Windows 10 without touching Windows Update.
$ErrorActionPreference = 'Continue'
$Proxy = 'http://127.0.0.1:7897'
$envbin = 'C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt'
$env:PATH = "$envbin\Library\bin;$envbin\Library\x86_64-w64-mingw32\bin;$envbin\bin;$env:PATH"
$run = 'H:\leonida\agprobe_r'
$cache = 'H:\leonida\agility_cache'
New-Item -ItemType Directory -Force -Path $cache, $run | Out-Null

$vers = @('1.600.2', '1.601.1', '1.602.3', '1.604.2', '1.606.2', '1.608.2')
$results = @()
foreach ($v in $vers) {
    $sdk = [int](($v -split '\.')[1])
    $dir = Join-Path $cache $v
    $dll = "$dir\build\native\bin\x64\D3D12Core.dll"
    if (-not (Test-Path $dll)) {
        $zip = "H:\leonida\agility_$v.zip"
        $url = "https://api.nuget.org/v3-flatcontainer/microsoft.direct3d.d3d12/$v/microsoft.direct3d.d3d12.$v.nupkg"
        try {
            if (-not (Test-Path $zip)) { Invoke-WebRequest -Uri $url -OutFile $zip -Proxy $Proxy -UseBasicParsing }
            Expand-Archive -Path $zip -DestinationPath $dir -Force
        } catch { $results += "$v  download failed: $($_.Exception.Message)"; continue }
    }
    if (-not (Test-Path $dll)) { $results += "$v  no D3D12Core.dll in package"; continue }

    $exe = "ag_$sdk.exe"
    Push-Location 'H:\leonida'
    & g++.exe -std=gnu++17 -D_WIN32_WINNT=0x0A00 "-DAGILITY_VERSION=$sdk" -o "$run\$exe" ag_probe.cpp -luuid 2>&1 | Out-Null
    Pop-Location
    if (-not (Test-Path "$run\$exe")) { $results += "$v (sdk $sdk)  probe build failed"; continue }

    Remove-Item "$run\D3D12" -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path "$run\D3D12" | Out-Null
    Copy-Item $dll "$run\D3D12\D3D12Core.dll" -Force
    Push-Location $run
    $out = & ".\$exe" 2>&1 | Out-String
    $code = $LASTEXITCODE
    Pop-Location
    $loaded = if ($out -match 'D3D12Core\.dll\s+(\S+)') { $matches[1] } else { 'none' }
    $sm = if ($out -match 'asking for 6\.6: (\S+)') { $matches[1] } else { '?' }
    $init = if ($out -match 'FAILED err=(\d+)') { 'err ' + $matches[1] } else { 'ok' }
    $results += ("sdk {0,3}  Agility {1}  create={2}  SM6.6->{3,-6}  D3D12Core={4}  exit={5}" -f $sdk, $v, $init, $sm, $loaded, $code)
}
$results | ForEach-Object { Write-Output $_ }
Write-Output 'DONE_SWEEP'
