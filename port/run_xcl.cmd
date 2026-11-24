@echo off
setlocal
set CARGO_HOME=H:\leonida\rust\cargo
set RUSTUP_HOME=H:\leonida\rust\rustup
set PATH=H:\leonida\rust\cargo\bin;%PATH%
rem XCL's own environment (README 94-101, crates/xcl/src/config.rs, gpu/recomp/dxc.rs:376-385,
rem hle/d3d12x/vram.rs:647-662).  This machine: 32 threads, 64 GB RAM, RTX 3080 20 GB.
set XCL_DXC_DIR=H:\leonida\dxc\bin\x64
set XCL_D3D12_DIR=H:\leonida\agility\build\native\bin\x64
set XCL_DATA_ROOT=H:\leonida\xcl-data
rem DXC compiles take 0.1-0.3 GB each at peak (issue #113 / PR #139); the default is
rem cores-1 = 31 threads (dxc.rs:385), which is what took a 32 GB machine to its knees in
rem issue #542.  With 64 GB here the default is affordable, but 14 keeps the machine usable
rem and matches the 14 jobs we use for the Leonida shader shards.
if "%XCL_DXC_THREADS%"=="" set XCL_DXC_THREADS=14
if "%1"=="" goto :usage
rem %* is expanded when this line is parsed, so pass the arguments through unchanged
rem (subcommand included) instead of shifting and re-quoting them.
if /i "%1"=="inspect" (
  "H:\leonida\xcl\target\release\xcl.exe" %*
) else if /i "%1"=="run" (
  "H:\leonida\xcl\target\release\xcl.exe" %*
) else (
  echo mode must be inspect or run
  exit /b 2
)
echo xcl_exit=%ERRORLEVEL%
exit /b %ERRORLEVEL%
:usage
echo usage: run_xcl.cmd inspect^|run "G:\game\dir" [-- extra args]
endlocal
