@echo off
setlocal
set XCL_DXC_DIR=H:\leonida\dxc\bin\x64
set XCL_D3D12_DIR=H:\leonida\agility\build\native\bin\x64
set XCL_DATA_ROOT=H:\leonida\xcl-data
set CARGO_HOME=H:\leonida\rust\cargo
set PATH=H:\leonida\rust\cargo\bin;%PATH%
cd /d H:\leonida\xcl\target\release
echo === free commit before the run ===
powershell.exe -NoProfile -Command "$m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; 'avail_commit_GB=' + [math]::Round(($m.CommitLimit-$m.CommittedBytes)/1GB,1) + '  free_phys_GB=' + [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,1)"
echo === xcl shaders stats (no compile, no GPU) ===
"xcl.exe" shaders "H:\GTA6\GTA6.Xbox.v1.0.2.1-CYBERLEEK\shaders.rpf" --top 20 2>&1 | findstr /i /c:"DXC" /c:"compile threads" /c:"records" /c:"programs" /c:"#542" /c:"top " /c:"shader" /c:"error"
echo shaders_exit=%ERRORLEVEL%
endlocal
