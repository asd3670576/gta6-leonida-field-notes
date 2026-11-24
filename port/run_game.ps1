# Run gta6rt against our package with the warm corpus cache, sampling the GPU the
# whole time so "did it actually use the GPU" is answered with evidence.
#
# Launch mechanics that were necessary on this machine:
#  - PowerShell 5.1's Start-Process (and even `Get-ChildItem env:`) throw
#    "Item has already been added. Key in dictionary: 'NO_PROXY'" because the
#    environment holds both NO_PROXY and no_proxy. .NET Process copies the block
#    verbatim instead of building a dictionary, so it is immune.
#  - Passing a quoted command line through ProcessStartInfo to cmd.exe proved
#    fragile, so each run writes its own .cmd (the pattern that already works
#    for the shader shards) and cmd does the file redirection itself.
#
# Layout rule (runtime/shims/d3d12_vulkan_device.cpp:129-135): the runtime loads
# pipeline_cache.bin from the folder holding gta6rt.exe - exact name, no flag.
# H:\leonida\out already holds the corpus cache, so the binaries go there.
param(
    [ValidateSet('dry-run', 'init', 'run')] [string]$Mode = 'run',
    [string]$Artifact = 'H:\leonida\runtime-ci3\unzipped',
    [int]$TimeoutSec = 900,
    [switch]$Trace,
    [switch]$D3dTrace,
    [switch]$Validation,
    [switch]$SkipInt3,
    [string]$Unimplemented = '',
    [string]$Tag = ''
)
$ErrorActionPreference = 'Continue'
$game = 'H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK'
$outDir = 'H:\leonida\out'
$exe = Join-Path $outDir 'gta6rt.exe'
$overlay = 'H:\leonida\overlay'
$logs = 'H:\leonida\logs'
if (-not $Tag) { $Tag = (Get-Date).ToString('HHmmss') }

foreach ($f in 'gta6rt.exe', 'gta6rt_tls_host.dll') {
    $src = Join-Path $Artifact $f
    if (-not (Test-Path $src)) { Write-Output "MISSING $src"; exit 1 }
    Copy-Item $src (Join-Path $outDir $f) -Force
}
Write-Output ("gta6rt.exe sha256 " + (Get-FileHash $exe -Algorithm SHA256).Hash)
$cache = Join-Path $outDir 'pipeline_cache.bin'
Write-Output ("pipeline_cache.bin = " + (Get-Item $cache).Length + " bytes, mtime " + (Get-Item $cache).LastWriteTime.ToString('HH:mm:ss'))

$log = Join-Path $logs ("gta6rt_{0}_{1}.log" -f $Mode, $Tag)
$gpuLog = Join-Path $logs ("gpu_{0}_{1}.csv" -f $Mode, $Tag)
$traceFile = ''
if ($Trace) {
    $traceFile = Join-Path $logs ("trace_{0}_{1}.jsonl" -f $Mode, $Tag)
    Remove-Item $traceFile -Force -ErrorAction SilentlyContinue   # the runtime refuses an existing path
}
Remove-Item $log, $gpuLog -Force -ErrorAction SilentlyContinue

# Build the batch for this run. Env var names are exactly what the code reads:
#   LEONIDA_D3D12      runtime/shims/d3d12_xs.cpp:165  (value "vulkan")
#   LEONIDA_SHADERS    runtime/src/main.cpp:125-131 + d3d12_vulkan_device.cpp:10034-10042
#   LEONIDA_VK_VALIDATION  d3d12_vulkan_device.cpp:9324-9357  (diagnostic, slows startup)
#   LEONIDA_UNIMPLEMENTED  shims/registry.cpp:294-317  (log | fail | stop)
$bat = @(
    '@echo off'
    'setlocal'
    'set LEONIDA_D3D12=vulkan'
    'set LEONIDA_SHADERS=H:\leonida\work\shaders\spirv'
    'set LEONIDA_W64_EMULATE=1'
    'cd /d H:\leonida\out'
)
if ($Validation) { $bat += 'set LEONIDA_VK_VALIDATION=1' }
# LEONIDA_SKIP_INT3 (docs/boot.md:79-82, shims/startup_trace.h:194-198) steps
# over each guest int3 and logs one int3_skipped event per address - it needs
# --trace. It is the only way past the game's own debugbreak asserts.
if ($SkipInt3) { $bat += 'set LEONIDA_SKIP_INT3=1' }
# LEONIDA_UNIMPLEMENTED log|fail|stop (shims/registry.cpp:294-317): stop ends the
# process with exit 3 and prints the caller, pinning the first blocker.
if ($Unimplemented) { $bat += ('set LEONIDA_UNIMPLEMENTED=' + $Unimplemented) }
$cmd = '"' + $exe + '" --' + $Mode + ' "' + $game + '\game_scarlett_master.exe" --game-dir "' + $game + '" --overlay "' + $overlay + '"'
if ($Trace) { $cmd += ' --trace "' + $traceFile + '"' }
if ($D3dTrace) { $cmd += ' --trace-d3d12' }
$bat += ($cmd + ' > "' + $log + '" 2>&1')
$bat += 'endlocal'
$batFile = Join-Path $logs ("launch_{0}_{1}.cmd" -f $Mode, $Tag)
Set-Content $batFile -Encoding ascii -Value $bat
Write-Output ("batch: " + $bat[-2])

"timestamp,util_pct,mem_used_MiB,mem_total_MiB,gta6rt_pid,gta6rt_cpu_s,log_bytes" | Set-Content $gpuLog -Encoding ascii

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\cmd.exe"
$psi.Arguments = '/c "' + $batFile + '"'
$psi.WorkingDirectory = $outDir
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
Write-Output ("mode=$Mode started " + (Get-Date -Format HH:mm:ss) + "  log=$log")

$t0 = Get-Date
$p = [System.Diagnostics.Process]::Start($psi)
$reason = 'exited'
$samples = 0
while ($true) {
    Start-Sleep -Seconds 10
    $el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 0)
    $done = $p.WaitForExit(0)
    $g = Get-Process gta6rt -ErrorAction SilentlyContinue | Select-Object -First 1
    $sm = (& nvidia-smi.exe --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null) -split ',\s*'
    $logBytes = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
    $row = (Get-Date -Format HH:mm:ss) + ',' + ($sm -join ',') + ',' + $(if ($g) { $g.Id } else { '' }) + ',' + $(if ($g) { [math]::Round($g.CPU) } else { '' }) + ",$logBytes"
    Add-Content $gpuLog $row
    $samples++
    if ($done) { break }
    if ($el -ge $TimeoutSec) {
        $reason = "timeout after ${TimeoutSec}s"
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        break
    }
}
$el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$code = if ($null -ne $p.ExitCode) { $p.ExitCode } else { 'killed' }
Write-Output ("$reason exit=$code elapsed_s=$el samples=$samples")

Write-Output "=== GPU / process samples (up to 12) ==="
Get-Content $gpuLog -Encoding ascii | Select-Object -First 13 | ForEach-Object { Write-Output $_ }

Write-Output ("=== log (" + $(if (Test-Path $log) { (Get-Item $log).Length } else { 0 }) + " bytes) tail 40 ===")
if (Test-Path $log) {
    Get-Content $log -Encoding utf8 -Tail 40 | ForEach-Object { Write-Output $_.ToString() }
    Write-Output "=== interesting lines (first 60) ==="
    Select-String -Path $log -Pattern 'unimplemented|error|\[rt\]|exited with code|running |console paths|pipeline_cache|translated shaders|assert|exception|subgroup|mesh|stubs|no translated' |
        Select-Object -First 60 | ForEach-Object { Write-Output $_.Line.Trim() }
}
if ($traceFile -and (Test-Path $traceFile)) {
    Write-Output ("=== trace records (" + @(Get-Content $traceFile -Encoding utf8).Count + "), last 12 ===")
    Get-Content $traceFile -Encoding utf8 | Select-Object -Last 12 | ForEach-Object { Write-Output $_.ToString() }
}
