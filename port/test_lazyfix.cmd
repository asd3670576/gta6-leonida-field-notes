@echo off
setlocal
set CARGO_HOME=H:\leonida\rust\cargo
set RUSTUP_HOME=H:\leonida\rust\rustup
set ENVBIN=C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt
set PATH=H:\leonida\rust\cargo\bin;%ENVBIN%\Library\bin;%ENVBIN%\Library\x86_64-w64-mingw32\bin;%ENVBIN%\bin;%PATH%
cd /d H:\leonida\xcl
echo === build ===
cargo.exe build --release --workspace 1> H:\leonida\logs\lazyfix_build.txt 2>&1
echo build_exit=%ERRORLEVEL%
echo === 5 runs of the lazy tests on the default thread count (the case that used to be flaky) ===
for /L %%i in (1,1,5) do (
  cargo.exe test --release -p xcl --lib -- kernelx::lazy 1> H:\leonida\logs\lazyfix_t%%i.txt 2>&1
  echo run %%i exit=%ERRORLEVEL%
  powershell.exe -NoProfile -Command "Get-Content 'H:\leonida\logs\lazyfix_t%%i.txt' | Select-String -Pattern 'test result|FAILED|panicked|SKIPPED' | ForEach-Object { '   ' + $_.Line.Trim() }"
)
echo === both modules together, default threads, 3 runs ===
for /L %%i in (1,1,3) do (
  cargo.exe test --release -p xcl --lib -- kernelx::lazy gpu::recomp::dxc 1> H:\leonida\logs\lazyfix_b%%i.txt 2>&1
  echo both run %%i exit=%ERRORLEVEL%
  powershell.exe -NoProfile -Command "Get-Content 'H:\leonida\logs\lazyfix_b%%i.txt' | Select-String -Pattern 'test result|FAILED|panicked' | ForEach-Object { '   ' + $_.Line.Trim() }"
)
endlocal
