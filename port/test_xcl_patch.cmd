@echo off
setlocal
set CARGO_HOME=H:\leonida\rust\cargo
set RUSTUP_HOME=H:\leonida\rust\rustup
set PATH=H:\leonida\rust\cargo\bin;C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt\Library\bin;C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt\Library\x86_64-w64-mingw32\bin;C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt\bin;%PATH%
set HTTP_PROXY=http://127.0.0.1:7897
set HTTPS_PROXY=http://127.0.0.1:7897
set NO_PROXY=
cd /d H:\leonida\xcl
echo === build === > H:\leonida\logs\xcl_patch_build.txt
cargo.exe build --release --workspace >> H:\leonida\logs\xcl_patch_build.txt 2>&1
echo build_exit=%ERRORLEVEL% >> H:\leonida\logs\xcl_patch_build.txt
powershell.exe -NoProfile -Command "Get-Content H:\leonida\logs\xcl_patch_build.txt -Tail 30"
echo === unit tests for the two changed modules ===
cargo.exe test --release -p xcl --lib -- kernelx::lazy gpu::recomp::dxc 1> H:\leonida\logs\xcl_patch_test.txt 2>&1
echo test_exit=%ERRORLEVEL%
powershell.exe -NoProfile -Command "Get-Content H:\leonida\logs\xcl_patch_test.txt -Tail 30"
endlocal
