@echo off
setlocal
set CARGO_HOME=H:\leonida\rust\cargo
set RUSTUP_HOME=H:\leonida\rust\rustup
set ENVBIN=C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt
set PATH=H:\leonida\rust\cargo\bin;%ENVBIN%\Library\bin;%ENVBIN%\Library\x86_64-w64-mingw32\bin;%ENVBIN%\bin;%PATH%
set HTTP_PROXY=http://127.0.0.1:7897
set HTTPS_PROXY=http://127.0.0.1:7897
set NO_PROXY=
set CARGO_NET_OPT__HTTP_PROXY=http://127.0.0.1:7897
cd /d H:\leonida\xcl
echo === cargo build --release --workspace === > H:\leonida\logs\xcl_build.txt
cargo.exe build --release --workspace >> H:\leonida\logs\xcl_build.txt 2>&1
echo build_exit=%ERRORLEVEL% >> H:\leonida\logs\xcl_build.txt
powershell.exe -NoProfile -Command "Get-Content H:\leonida\logs\xcl_build.txt -Tail 40"
if exist H:\leonida\xcl\target\release\xcl.exe ( echo XCL_EXE_FOUND & dir H:\leonida\xcl\target\release\xcl.exe | findstr xcl.exe ) else ( echo XCL_EXE_MISSING )
endlocal
