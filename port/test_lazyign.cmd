@echo off
setlocal
set CARGO_HOME=H:\leonida\rust\cargo
set RUSTUP_HOME=H:\leonida\rust\rustup
set ENVBIN=C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt
set PATH=H:\leonida\rust\cargo\bin;%ENVBIN%\Library\bin;%ENVBIN%\Library\x86_64-w64-mingw32\bin;%ENVBIN%\bin;%PATH%
cd /d H:\leonida\xcl
for /L %%i in (1,1,4) do (
  cargo.exe test --release -p xcl --lib -- kernelx::lazy 1> H:\leonida\logs\lazyign_%%i.txt 2>&1
  echo run %%i exit=%ERRORLEVEL%
  powershell.exe -NoProfile -Command "Get-Content 'H:\leonida\logs\lazyign_%%i.txt' | Select-String -Pattern 'test result|FAILED|panicked' | ForEach-Object { '   ' + $_.Line.Trim() }"
)
echo === the ignored test, run on its own with --ignored --ignored ===
cargo.exe test --release -p xcl --lib -- --ignored --exact hle::kernelx::lazy::tests::a_failed_commit_keeps_the_page_lazy_and_says_so 1> H:\leonida\logs\lazyign_only.txt 2>&1
echo ignored_exit=%ERRORLEVEL%
powershell.exe -NoProfile -Command "Get-Content 'H:\leonida\logs\lazyign_only.txt' | Select-String -Pattern 'test result|ok\.|FAILED|panicked|SKIPPED|assert' | ForEach-Object { '   ' + $_.Line.Trim() } | Select-Object -First 12"
endlocal
