# Run XCL (github.com/ivall/xcl) against our verified GTA VI 1.0.2.1 package, sampling the
# GPU and the process's memory the whole time.  The samples are the point: XCL's own OOM
# reports (#542/#345/#333/#467) come from 16 GB and 32 GB machines, so on 64 GB RAM /
# 20 GB VRAM we can see which mechanism actually fires and which ones never apply.
param(
    [int]$TimeoutSec = 1080,
    [int]$DxcThreads = 14,
    [string]$ExtraEnv = '',
    [string]$GameDir = 'H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK',
    [string]$Tag = ''
)
$ErrorActionPreference = 'Continue'
if (-not $Tag) { $Tag = (Get-Date).ToString('HHmmss') }
$logs = 'H:\leonida\logs'
$xclExe = 'H:\leonida\xcl\target\release\xcl.exe'
$dataRoot = 'H:\leonida\xcl-data'
New-Item -ItemType Directory -Force -Path $dataRoot | Out-Null
$log = Join-Path $logs ("xcl_run_{0}.log" -f $Tag)
$samples = Join-Path $logs ("xcl_mem_{0}.csv" -f $Tag)
# XCL writes its own detailed log here; a previous run's copy must not be mistaken for ours.
$xclLog = ''   # resolved at the end: <XCL_DATA_ROOT>\XCL\<title>\logs\xcl.log (README:144)
Remove-Item $log, $samples -Force -ErrorAction SilentlyContinue

$bat = @(
    '@echo off'
    'setlocal'
    'set XCL_DXC_DIR=H:\leonida\dxc\bin\x64'
    'set XCL_D3D12_DIR=H:\leonida\agility\build\native\bin\x64'
    "set XCL_DATA_ROOT=$dataRoot"
    "set XCL_DXC_THREADS=$DxcThreads"
    'set CARGO_HOME=H:\leonida\rust\cargo'
    'set PATH=H:\leonida\rust\cargo\bin;%PATH%'
)
if ($ExtraEnv) { $bat += ('set ' + $ExtraEnv) }
$bat += ('"' + $xclExe + '" run "' + $GameDir + '" > "' + $log + '" 2>&1')
$batFile = Join-Path $logs ("launch_xcl_{0}.cmd" -f $Tag)
Set-Content $batFile -Encoding ascii -Value $bat
Write-Output ('batch: ' + $bat[-1])

"timestamp,util_pct,vram_used_MiB,vram_total_MiB,xcl_pid,xcl_cpu_s,xcl_ws_MiB,xcl_private_MiB,system_free_MiB,system_commit_MiB,commit_limit_MiB,log_bytes" | Set-Content $samples -Encoding ascii

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\cmd.exe"
$psi.Arguments = '/c "' + $batFile + '"'
$psi.WorkingDirectory = 'H:\leonida\xcl\target\release'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
Write-Output ("xcl run started " + (Get-Date -Format HH:mm:ss) + "  log=$log  timeout=${TimeoutSec}s")
$t0 = Get-Date
$p = [System.Diagnostics.Process]::Start($psi)
$reason = 'exited'
$n = 0
while ($true) {
    Start-Sleep -Seconds 15
    $el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 0)
    $done = $p.WaitForExit(0)
    $g = Get-Process xcl -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $sm = (& nvidia-smi.exe --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null) -split ',\s*'
    $logBytes = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
    $row = @(
        (Get-Date -Format HH:mm:ss),
        $(if ($sm.Count -ge 2) { $sm[0] } else { '' }),
        $(if ($sm.Count -ge 2) { $sm[1] } else { '' }),
        $(if ($sm.Count -ge 3) { $sm[2] } else { '' }),
        $(if ($g) { $g.Id } else { '' }),
        $(if ($g) { [math]::Round($g.CPU) } else { '' }),
        $(if ($g) { [math]::Round($g.WorkingSet64 / 1MB) } else { '' }),
        $(if ($g) { [math]::Round($g.PrivateMemorySize64 / 1MB) } else { '' }),
        $(if ($os) { [math]::Round($os.FreePhysicalMemory / 1KB) } else { '' }),
        $(if ($os) { [math]::Round($os.TotalVirtualMemorySize / 1KB) } else { '' }),
        $(if ($os) { [math]::Round($os.TotalVirtualMemorySize / 1KB) } else { '' }),
        $logBytes
    ) -join ','
    Add-Content $samples -Encoding ascii -Value $row
    $n++
    if ($done) { break }
    if ($el -ge $TimeoutSec) {
        $reason = "timeout after ${TimeoutSec}s (still running: pid $($p.Id))"
        try { $p.Kill($true) } catch { Write-Output ('kill failed: ' + $_.Exception.Message) }
        Start-Sleep -Seconds 3
        break
    }
}
if (-not $p.WaitForExit(0)) { $p.WaitForExit() }
Write-Output ("reason=$reason exit=" + $(try { $p.ExitCode } catch { 'n/a' }) + ' elapsed_s=' + [math]::Round(((Get-Date) - $t0).TotalSeconds, 0) + " samples=$n")

Write-Output '=== samples (first 6, last 8) ==='
$all = Get-Content $samples
if ($all.Count -le 14) { $all } else { ($all | Select-Object -First 6); '...'; ($all | Select-Object -Last 8) }

Write-Output '=== interesting lines from xcl stdout (first 80) ==='
if (Test-Path $log) {
    Get-Content $log | Select-String -Pattern 'crash|CRASH|unhandled|exception|STUB|refused|failed|error|PresentX|presents|fps|memory|coherent|sparse|DXC|dxc|title memory|watchdog|out of|E_OUTOFMEMORY|Commitment' |
        Select-Object -First 80 | ForEach-Object { $_.Line }
}
Write-Output '=== tail of xcl stdout (last 30) ==='
if (Test-Path $log) { Get-Content $log -Tail 30 }
Write-Output '=== tail of XCL title logs\xcl.log (last 30) ==='
$xclLog = Get-ChildItem $dataRoot -Recurse -File -Filter 'xcl.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($xclLog) { Write-Output $xclLog.FullName; Get-Content $xclLog.FullName -Tail 30 } else { Write-Output "no xcl.log under $dataRoot" }
Write-Output '=== report.json (first 60 lines) ==='
$report = Get-ChildItem $dataRoot -Recurse -File -Filter 'report.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($report) { Write-Output $report.FullName; Get-Content $report.FullName -TotalCount 60 } else { Write-Output "no report.json under $dataRoot" }
Write-Output '=== files under XCL_DATA_ROOT ==='
Get-ChildItem $dataRoot -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 25 | ForEach-Object { $_.FullName + '  ' + $_.Length }
