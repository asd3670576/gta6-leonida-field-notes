# Sequential boot ladder for the artifact we compiled ourselves (H:\leonida\rt-build).
# Each step calls run_game.ps1 so the launch mechanics (per-run .cmd, .NET Process,
# GPU sampling, cache next to the exe) stay identical to the CI-artifact runs - only
# the binary changes, which is what makes the comparison meaningful.
$ErrorActionPreference = 'Continue'
$art = 'H:\leonida\rt-build'

Write-Output '=== STEP 1: --init --trace ==='
& 'H:\leonida\run_game.ps1' -Mode init -Artifact $art -TimeoutSec 180 -Trace

Write-Output '=== STEP 2: --run --trace (native stop) ==='
& 'H:\leonida\run_game.ps1' -Mode run -Artifact $art -TimeoutSec 300 -Trace

Write-Output '=== STEP 3: --run --trace + LEONIDA_SKIP_INT3=1 ==='
& 'H:\leonida\run_game.ps1' -Mode run -Artifact $art -TimeoutSec 300 -Trace -SkipInt3

Write-Output '=== ALL STEPS DONE ==='
