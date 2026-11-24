# XCL memory / VRAM curve for the GTA VI run, with XCL's own accounting line alongside.
# Our first run (12:37) showed VRAM at 20091/20480 MiB and free physical RAM at 2937 MiB of
# 64 GB 20 s in - so on a 64 GB / 20 GB machine the memory question is still live. This
# samples the real counters (commit charge, not just totals) plus XCL's own
# "coherent N/M MB, sparse K MB, B blocks held for B allocators" line over time.
param(
    [int]$TimeoutSec = 900,
    [int]$DxcThreads = 14,
    [string]$ExtraEnv = '',
    [string]$TitleMemMb = '',
    [string]$UmaMb = '',
    [string]$Tag = ''
)
$ErrorActionPreference = 'Continue'
if (-not $Tag) { $Tag = (Get-Date).ToString('HHmmss') }
$logs = 'H:\leonida\logs'
$xclExe = 'H:\leonida\xcl\target\release\xcl.exe'
$dataRoot = 'H:\leonida\xcl-data'
$game = 'H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK'
$log = Join-Path $logs ("xcl_run_{0}.log" -f $Tag)
$samples = Join-Path $logs ("xcl_mem_{0}.csv" -f $Tag)
Remove-Item $log, $samples -Force -ErrorAction SilentlyContinue
# A fresh title folder: the adaptive coherent-window cache (cache/uma_coherent.txt) and
# xcl.toml from an earlier run would otherwise carry over into this measurement.
$titleDir = Join-Path $dataRoot 'RockstarGamesInc.28872443D20A7'
Remove-Item $titleDir -Recurse -Force -ErrorAction SilentlyContinue

$bat = @(
    '@echo off'
    'setlocal'
    'set XCL_DXC_DIR=H:\leonida\dxc\bin\x64'
    'set XCL_D3D12_DIR=H:\leonida\agility\build\native\bin\x64'
    "set XCL_DATA_ROOT=$dataRoot"
    "set XCL_DXC_THREADS=$DxcThreads"
)
if ($ExtraEnv) { foreach ($kv in ($ExtraEnv -split ';')) { if ($kv) { $bat += ('set ' + $kv) } } }
$bat += ('"' + $xclExe + '" run "' + $game + '" > "' + $log + '" 2>&1')
$batFile = Join-Path $logs ("launch_xcl_{0}.cmd" -f $Tag)
Set-Content $batFile -Encoding ascii -Value $bat
Write-Output ('env: ' + (($bat | Select-Object -Skip 2 | Select-Object -First 8) -join '  '))

"t,wall_s,util_pct,vram_MiB,vram_total,xcl_pid,xcl_threads,xcl_ws_MiB,xcl_private_MiB,free_phys_MiB,commit_MiB,commit_limit_MiB,xcl_log_bytes,xcl_accounting" | Set-Content $samples -Encoding ascii

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\cmd.exe"
$psi.Arguments = '/c "' + $batFile + '"'
$psi.WorkingDirectory = 'H:\leonida\xcl\target\release'
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
Write-Output ("started " + (Get-Date -Format HH:mm:ss) + " log=$log timeout=${TimeoutSec}s")
$t0 = Get-Date
$p = [System.Diagnostics.Process]::Start($psi)
$reason = 'exited'
$rows = 0
while ($true) {
    Start-Sleep -Seconds 10
    $el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 0)
    $done = $p.WaitForExit(0)
    $g = Get-Process xcl -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $mm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    $sm = (& nvidia-smi.exe --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null) -split ',\s*'
    # XCL's own running total of what it has handed the title, straight from its log.
    $acct = ''
    $tlog = Get-ChildItem $dataRoot -Recurse -File -Filter 'xcl.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($tlog) {
        $acct = (Get-Content $tlog.FullName -Tail 600 -ErrorAction SilentlyContinue |
                 Select-String -Pattern 'coherent .*/.* MB, sparse' | Select-Object -Last 1 | ForEach-Object { $_.Line })
        if ($acct) { $acct = $acct -replace ',', ';' }
    }
    $row = @(
        (Get-Date -Format HH:mm:ss), $el,
        $(if ($sm.Count -ge 2) { $sm[0] } else { '' }),
        $(if ($sm.Count -ge 3) { $sm[1] } else { '' }),
        $(if ($sm.Count -ge 3) { $sm[2] } else { '' }),
        $(if ($g) { $g.Id } else { '' }),
        $(if ($g) { $g.Threads.Count } else { '' }),
        $(if ($g) { [math]::Round($g.WorkingSet64 / 1MB) } else { '' }),
        $(if ($g) { [math]::Round($g.PrivateMemorySize64 / 1MB) } else { '' }),
        $(if ($os) { [math]::Round($os.FreePhysicalMemory / 1KB) } else { '' }),
        $(if ($mm) { [math]::Round($mm.CommittedBytes / 1MB) } else { '' }),
        $(if ($mm) { [math]::Round($mm.CommitLimit / 1MB) } else { '' }),
        $(if ($tlog) { $tlog.Length } else { 0 }),
        $acct
    ) -join ','
    Add-Content $samples -Encoding ascii -Value $row
    $rows++
    if ($done) { break }
    if ($el -ge $TimeoutSec) {
        $reason = "timeout ${TimeoutSec}s (still running pid $($p.Id))"
        try { $p.Kill($true) } catch { Write-Output ('kill failed: ' + $_.Exception.Message) }
        Start-Sleep -Seconds 5
        break
    }
}
if (-not $p.WaitForExit(0)) { $p.WaitForExit() }
Write-Output ('reason=' + $reason + ' exit=' + $(try { $p.ExitCode } catch { '?' }) + " rows=$rows")
Write-Output '=== memory curve ==='
Get-Content $samples | ForEach-Object { $_.Substring(0, [Math]::Min(150, $_.Length)) }
Write-Output '=== crash / error lines ==='
if (Test-Path $log) {
    Get-Content $log | Select-String -Pattern 'CRASH|unhandled|exited with code|ERROR|Missing on this PC|Game exited|E_OUTOFMEMORY|no video memory|coherent|Out of memory' |
        Select-Object -Last 14 | ForEach-Object { $_.Line }
}
Write-Output '=== report.json memory-relevant keys ==='
$rep = Get-ChildItem $dataRoot -Recurse -File -Filter 'report.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($rep) {
    Write-Output $rep.FullName
    $j = Get-Content $rep.FullName -Raw | ConvertFrom-Json
    foreach ($prop in $j.PSObject.Properties) {
        if ($prop.Name -match 'memory|uma|vram|crash|exit|title|presents|frames|shader|pipeline|dxc') {
            $v = $prop.Value
            if ($v -is [System.Object]) { $v = ($v | ConvertTo-Json -Compress -Depth 3) }
        # report.json's "shaders" block carries the whole RDNA2 mnemonic histogram; keep the
        # console output small and read the JSON file itself for detail.
        if ($v.Length -gt 300) { $v = $v.Substring(0, 300) + ' …' }
            Write-Output ("  " + $prop.Name + " = " + $v)
        }
    }
}
Write-Output ('samples: ' + $samples)
Write-Output ('stdout : ' + $log)
