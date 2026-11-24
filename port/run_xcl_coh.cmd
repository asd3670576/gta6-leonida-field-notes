@echo off
setlocal
rem Batch owns the quoting: the ; inside -ExtraEnv must survive into PowerShell's arg parser.
set TAG=%1
if "%TAG%"=="" set TAG=coh512
powershell.exe -NoProfile -ExecutionPolicy Bypass -File H:\leonida\watch_xcl_mem.ps1 -TimeoutSec 300 -ExtraEnv "XCL_COHERENT_MB=512;XCL_ACTIVITY=1" -Tag %TAG% 1> "H:\leonida\logs\%TAG%_report.txt" 2> "H:\leonida\logs\%TAG%_err.txt"
echo wrapper_exit=%ERRORLEVEL%
powershell.exe -NoProfile -Command "Get-Content 'H:\leonida\logs\%TAG%_err.txt' | Select-Object -Last 8"
powershell.exe -NoProfile -Command "Get-Content 'H:\leonida\logs\%TAG%_report.txt' -TotalCount 40"
endlocal
