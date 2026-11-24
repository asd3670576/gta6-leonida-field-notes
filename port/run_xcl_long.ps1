# Long-run harness for XCL + our package: fixed settings, preseeded learning cache,
# continuous memory/VRAM/GPU sampling, and a definite answer to "did it stay in the game".
#
# Why the pieces are here (all measured by us or read from the XCL source):
#  - cache/uma_coherent.txt: XCL learns the coherent window size across runs; a cold start runs
#    at ~9 fps and a learned 4095 MB at ~30 fps, so we seed it instead of paying the ramp.
#  - XCL_COHERENT_MB (crates/xcl/src/gpu/uma.rs:679-681): the only thing that pins that window
#    - uma_mb alone is overridden by the learned value (uma.rs:170,739).
#  - title_memory_mb in xcl.toml: the lever that shrinks BOTH host RAM and VRAM, because the
#    engine sizes its own streaming pools from the budget XCL reports.
#  - XCL_FRAME_DUMP=N: XCL samples presented frames and writes d3d12.last_frame_dump with
#    non_dark_samples - objective evidence that something was on screen, not just a present call.
#  - XCL_ACTIVITY=1: XCL's own ~2 s breakdown of memory and frames (host.rs:32-75).
#  - XCL_NETWORK=0: offline, no Xbox Live / backtrace.io chatter (upstream #232 verified the
#    crash is the same with and without it, so it is safe for reproducibility).
param(
    [int]$Seconds = 1200,
    [string]$Exe = 'H:\leonida\xcl\target\release\xcl.exe',
    [string]$Graphics = 'd3d12',   # 'null' = XCL's null renderer: tells us whether a crash lives
                                   # in the graphics path at all, with no GPU work submitted
    [int]$CoherentMb = 0,          # 0 = use XCL's own logic; >0 = pin with XCL_COHERENT_MB
    [int]$TitleMemMb = 0,          # 0 = leave title_memory_mb = 0 (device standard budget)
    [int]$UmaMb = 0,               # 0 = XCL's default (4095 for an 'advanced' title)
    [int]$DxcThreads = 0,          # 0 = XCL's default (cores-1, capped by free commit in our build)
    [int]$FrameDump = 0,           # N > 1: sample N frames
    [int]$SampleSec = 10,
    [string]$ExtraEnv = '',
    [string]$Tag = ''
)
$ErrorActionPreference = 'Continue'
if (-not $Tag) { $Tag = (Get-Date).ToString('HHmmss') }
$logs = 'H:\leonida\logs'
$xclExe = $Exe
$dataRoot = 'H:\leonida\xcl-data'
$game = 'H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK'
$titleDir = Join-Path $dataRoot 'RockstarGamesInc.28872443D20A7'
$log = Join-Path $logs ("xcl_long_{0}.log" -f $Tag)
$samples = Join-Path $logs ("xcl_long_mem_{0}.csv" -f $Tag)
Remove-Item $log, $samples -Force -ErrorAction SilentlyContinue

# ---- title data directory: fresh, but with the coherent window preseeded ---------------------
Remove-Item $titleDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $titleDir 'cache') | Out-Null
if ($CoherentMb -le 0) {
    # 4095 MiB, the value upstream measured at ~30 fps. The file holds the size in bytes as text.
    Set-Content (Join-Path $titleDir 'cache\uma_coherent.txt') -Encoding ascii -Value '4293918720'
}

# ---- xcl.toml written by us, so every run starts from known settings -------------------------
# The key list is the one XCL itself generates (config.rs:197 aliases block included).
$bytes = if ($CoherentMb -gt 0) { 0 } else { 4293918720 }
$toml = @(
    'device_type = "anaconda"'
    'console_type_raw = 6'
    'gamertag = "Player1"'
    'sandbox_id = "RETAIL"'
    ('title_memory_mb = ' + $(if ($TitleMemMb -gt 0) { $TitleMemMb } else { 0 }))
    'title_memory = "auto"'
    ('uma_mb = ' + $(if ($UmaMb -gt 0) { $UmaMb } else { 0 }))
    'pls_mb = 0'
    'log_level = "info"'
    'log_to_stderr = true'
    'graphics = "d3d12"'
    'd3d12_adapter = "auto"'
    'd3d12_debug = false'
    'present = "auto"'
    'raytracing = "auto"'
    'window_width = 2560'
    'window_height = 1440'
    'window_pos = "auto"'
    'xbox_live_tokens = false'
    'keyboard_mouse = true'
    'mouse_sensitivity = 1.0'
    ''
    '[mounts]'
    '"D:" = "{game}"'
    '"G:" = "{game}"'
    '"GAME:" = "{game}"'
    '"S:" = ''{data}\pls'''
    '"T:" = ''{data}\temp'''
    ''
    '[aliases]'
    ''
    '[stub_returns]'
)
Set-Content (Join-Path $titleDir 'xcl.toml') -Encoding ascii -Value $toml
Write-Output ('xcl.toml: title_memory_mb=' + $TitleMemMb + ' uma_mb=' + $UmaMb +
              ' coherent_seeded_bytes=' + $bytes)

# ---- the launch batch ------------------------------------------------------------------------
$bat = @(
    '@echo off'
    'setlocal'
    'set XCL_DXC_DIR=H:\leonida\dxc\bin\x64'
    'set XCL_D3D12_DIR=H:\leonida\agility\build\native\bin\x64'
    "set XCL_DATA_ROOT=$dataRoot"
    'set XCL_NETWORK=0'
    'set XCL_ACTIVITY=1'
)
if ($CoherentMb -gt 0) { $bat += ('set XCL_COHERENT_MB=' + $CoherentMb) }
if ($DxcThreads -gt 0) { $bat += ('set XCL_DXC_THREADS=' + $DxcThreads) }
if ($FrameDump -gt 1) { $bat += ('set XCL_FRAME_DUMP=' + $FrameDump) }
if ($ExtraEnv) { foreach ($kv in ($ExtraEnv -split ';')) { if ($kv) { $bat += ('set ' + $kv) } } }
$bat += ('"' + $xclExe + '" run "' + $game + '" > "' + $log + '" 2>&1')
$batFile = Join-Path $logs ("launch_long_{0}.cmd" -f $Tag)
Set-Content $batFile -Encoding ascii -Value $bat
Write-Output ('env: ' + (($bat | Select-Object -Skip 2) -join '  '))

"t,wall_s,util_pct,vram_MiB,xcl_pid,threads,ws_MiB,private_MiB,free_phys_MiB,commit_MiB,commit_limit_MiB,xcl_log_bytes,xcl_accounting" | Set-Content $samples -Encoding ascii

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "$env:SystemRoot\System32\cmd.exe"
$psi.Arguments = '/c "' + $batFile + '"'
$psi.WorkingDirectory = Split-Path $xclExe -Parent
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
Write-Output ("started " + (Get-Date -Format HH:mm:ss) + "  budget=${Seconds}s  log=$log")
$t0 = Get-Date
$p = [System.Diagnostics.Process]::Start($psi)
$reason = 'exited'
$n = 0
while ($true) {
    Start-Sleep -Seconds $SampleSec
    $el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 0)
    $done = $p.WaitForExit(0)
    $g = Get-Process xcl -ErrorAction SilentlyContinue | Select-Object -First 1
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $mm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction SilentlyContinue
    $sm = (& nvidia-smi.exe --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>$null) -split ',\s*'
    $tlog = Join-Path $titleDir 'logs\xcl.log'
    $acct = ''
    $lb = 0
    if (Test-Path $tlog) {
        $lb = (Get-Item $tlog).Length
        $acct = (Get-Content $tlog -Tail 900 -ErrorAction SilentlyContinue |
                 Select-String -Pattern 'coherent .*/.* MB, sparse' | Select-Object -Last 1 | ForEach-Object { $_.Line })
        if ($acct) { $acct = $acct -replace ',', ';' }
    }
    $row = @(
        (Get-Date -Format HH:mm:ss), $el,
        $(if ($sm.Count -ge 2) { $sm[0] } else { '' }),
        $(if ($sm.Count -ge 2) { $sm[1] } else { '' }),
        $(if ($g) { $g.Id } else { '' }),
        $(if ($g) { $g.Threads.Count } else { '' }),
        $(if ($g) { [math]::Round($g.WorkingSet64 / 1MB) } else { '' }),
        $(if ($g) { [math]::Round($g.PrivateMemorySize64 / 1MB) } else { '' }),
        $(if ($os) { [math]::Round($os.FreePhysicalMemory / 1KB) } else { '' }),
        $(if ($mm) { [math]::Round($mm.CommittedBytes / 1MB) } else { '' }),
        $(if ($mm) { [math]::Round($mm.CommitLimit / 1MB) } else { '' }),
        $lb, $acct
    ) -join ','
    Add-Content $samples -Encoding ascii -Value $row
    $n++
    if ($done) { break }
    if ($el -ge $Seconds) {
        $reason = "reached the ${Seconds}s budget with the game still running"
        try { $p.Kill($true) } catch { }
        Start-Sleep -Seconds 5
        break
    }
}
if (-not $p.WaitForExit(0)) { $p.WaitForExit() }
$exit = try { $p.ExitCode } catch { '?' }
Write-Output ('result: ' + $reason + '  exit=' + $exit + '  samples=' + $n +
              '  wall_s=' + [math]::Round(((Get-Date) - $t0).TotalSeconds, 0))

Write-Output '=== memory / VRAM curve (first 8, last 10) ==='
$all = Get-Content $samples
if ($all.Count -le 20) { $all } else { ($all | Select-Object -First 8); '...'; ($all | Select-Object -Last 10) }

Write-Output '=== verdict lines from XCL ==='
if (Test-Path $log) {
    Get-Content $log | Select-String -Pattern 'CRASH|unhandled|Game exited|Missing on this PC|ERROR:|WARNING:|PresentX|presents|frames|no video memory|E_OUTOFMEMORY|lazy page commit' |
        Select-Object -Last 16 | ForEach-Object { $_.Line }
}
Write-Output '=== report.json: the parts that decide "did it really run" ==='
$rep = Join-Path $titleDir 'logs\report.json'
if (Test-Path $rep) {
    $j = Get-Content $rep -Raw | ConvertFrom-Json
    foreach ($name in 'crash', 'exit_code', 'title') {
        $v = $j.$name
        if ($v -and $v.Length -gt 300) { $v = $v.Substring(0, 300) + ' ...' }
        Write-Output ("  $name = $v")
    }
    if ($j.d3d12) {
        foreach ($prop in $j.d3d12.PSObject.Properties) {
            $v = "$($prop.Value)"
            if ($v.Length -gt 200) { $v = $v.Substring(0, 200) + ' ...' }
            Write-Output ("  d3d12." + $prop.Name + " = " + $v)
        }
    }
    if ($j.shaders) {
        foreach ($prop in $j.shaders.PSObject.Properties) {
            if ($prop.Name -match 'unique|submitted|recomp|dxc|xbox_errors|by_stage|by_kind') {
                Write-Output ("  shaders." + $prop.Name + " = " + ($prop.Value | ConvertTo-Json -Compress -Depth 2))
            }
        }
    }
} else { Write-Output "  no $rep" }
Write-Output ('samples file: ' + $samples)
Write-Output ('stdout file : ' + $log)
