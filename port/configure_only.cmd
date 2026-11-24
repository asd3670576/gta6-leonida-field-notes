@echo off
setlocal
set E=C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt
set PATH=%E%\Library\bin;%E%\Library\x86_64-w64-mingw32\bin;%PATH%
rmdir /s /q H:\leonida\rt-build 2>nul
"%E%\Library\bin\cmake.exe" -S H:\leonida\Leonida-continued\runtime -B H:\leonida\rt-build -G Ninja -DCMAKE_TOOLCHAIN_FILE=H:/leonida/leonida-mingw-toolchain.cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLEONIDA_REQUIRE_VULKAN=ON -DLEONIDA_SDL3=OFF -DBUILD_TESTING=OFF > H:\leonida\logs\rt_configure.txt 2>&1
echo configure_exit=%ERRORLEVEL%
endlocal
