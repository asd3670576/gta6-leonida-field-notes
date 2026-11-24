@echo off
setlocal
set E=C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt
set PATH=%E%\Library\bin;%E%\Library\x86_64-w64-mingw32\bin;%PATH%
"%E%\Library\bin\cmake.exe" --build H:\leonida\rt-build --target gta6rt gta6rt_tls_host -j 14 > H:\leonida\logs\rt_build.txt 2>&1
echo build_exit=%ERRORLEVEL%
powershell -NoProfile -Command "Get-Content 'H:\leonida\logs\rt_build.txt' -Tail 14"
powershell -NoProfile -Command "Get-ChildItem 'H:\leonida\rt-build' -Filter 'gta6rt*' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + ' ' + $_.Length }"
endlocal
