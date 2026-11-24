@echo off
setlocal
rem Configure + build the Leonida runtime with conda-forge MinGW GCC, no admin.
rem PATH must carry the env's Library\bin and Library\x86_64-w64-mingw32\bin, or
rem as.exe fails with exit 1 and no message (missing DLL dependencies).
set E=C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt
set PATH=%E%\Library\bin;%E%\Library\x86_64-w64-mingw32\bin;%PATH%
set SRC=H:\leonida\Leonida-continued
set BIN=H:\leonida\rt-build

echo == configure %date% %time% ==
rem The toolchain file's flags are baked into the CMake cache, so a stale
rem rt-build keeps reusing the previous linker flags. Start clean.
if exist "%BIN%" rmdir /s /q "%BIN%"
"%E%\Library\bin\cmake.exe" -S "%SRC%\runtime" -B "%BIN%" -G Ninja -DCMAKE_TOOLCHAIN_FILE=H:/leonida/leonida-mingw-toolchain.cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLEONIDA_REQUIRE_VULKAN=ON -DLEONIDA_SDL3=OFF -DBUILD_TESTING=OFF > H:\leonida\logs\rt_configure.txt 2>&1
echo configure_exit=%ERRORLEVEL%
echo == last 25 configure lines ==
more +0 < H:\leonida\logs\rt_configure.txt | findstr /N "." | findstr /R "^[1-9][0-9]*:" > nul
powershell -NoProfile -Command "Get-Content 'H:\leonida\logs\rt_configure.txt' -Tail 25"

echo == build gta6rt %date% %time% ==
"%E%\Library\bin\cmake.exe" --build "%BIN%" --target gta6rt gta6rt_tls_host -j 14 > H:\leonida\logs\rt_build.txt 2>&1
echo build_exit=%ERRORLEVEL%
powershell -NoProfile -Command "Get-Content 'H:\leonida\logs\rt_build.txt' -Tail 40"
echo == artifacts ==
powershell -NoProfile -Command "Get-ChildItem 'H:\leonida\rt-build' -Recurse -Include 'gta6rt.exe','gta6rt_tls_host.dll' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName + ' ' + $_.Length }"
endlocal
