@echo off
setlocal
set CARGO_HOME=H:\leonida\rust\cargo
set RUSTUP_HOME=H:\leonida\rust\rustup
set ENVBIN=C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt
set PATH=H:\leonida\rust\cargo\bin;%ENVBIN%\Library\bin;%ENVBIN%\Library\x86_64-w64-mingw32\bin;%ENVBIN%\bin;%PATH%
set CARGO_TARGET_DIR=H:\leonida\xcl-ours\target
cd /d H:\leonida\xcl-ours
cargo build --release --workspace 1> H:\leonida\logs\sm65gate_build.txt 2>&1
echo build_exit=%ERRORLEVEL%
powershell.exe -NoProfile -Command "Get-Content H:\leonida\logs\sm65gate_build.txt -Tail 12"
if exist H:\leonida\xcl-ours\target\release\xcl.exe copy /y H:\leonida\xcl-ours\target\release\xcl.exe H:\leonida\bin\ours\xcl.exe >nul && echo archived to H:\leonida\bin\ours\xcl.exe
endlocal
