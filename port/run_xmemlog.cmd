@echo off
setlocal
set LEONIDA_D3D12=vulkan
set LEONIDA_SHADERS=H:\leonida\work\shaders\spirv
set LEONIDA_W64_EMULATE=1
set LEONIDA_SKIP_INT3=1
set LEONIDA_XMEM_LOG=8
copy /y H:\leonida\rt-build\gta6rt.exe H:\leonida\out\gta6rt.exe >nul
copy /y H:\leonida\rt-build\gta6rt_tls_host.dll H:\leonida\out\gta6rt_tls_host.dll >nul
cd /d H:\leonida\out
del /q H:\leonida\logs\trace_xmemlog.jsonl 2>nul
"H:\leonida\out\gta6rt.exe" --run "H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK\game_scarlett_master.exe" --game-dir "H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK" --overlay "H:\leonida\overlay" --trace "H:\leonida\logs\trace_xmemlog.jsonl" > "H:\leonida\logs\gta6rt_xmemlog.txt" 2>&1
echo run_exit=%ERRORLEVEL%
endlocal
