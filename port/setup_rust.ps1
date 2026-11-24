# Install a Rust toolchain for XCL (github.com/ivall/xcl) without Visual Studio.
# This machine has no MSVC and no Windows SDK, so the MSVC ABI toolchain cannot link;
# the GNU ABI toolchain is the one that fits the MinGW-w64 we already installed, and
# XCL's own contributors build x86_64-pc-windows-gnu (issue #575 cross-builds it).
# Everything goes under H:\leonida\rust so the C: drive and the Chinese-named user
# profile stay out of the way.
$ErrorActionPreference = 'Continue'
$Proxy = 'http://127.0.0.1:7897'
$root = 'H:\leonida\rust'
$env:RUSTUP_HOME = Join-Path $root 'rustup'
$env:CARGO_HOME = Join-Path $root 'cargo'
New-Item -ItemType Directory -Force -Path $root, $env:RUSTUP_HOME, $env:CARGO_HOME | Out-Null
$init = Join-Path $root 'rustup-init.exe'
if (-not (Test-Path $init)) {
    Write-Output 'downloading rustup-init.exe'
    Invoke-WebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $init -Proxy $Proxy -UseBasicParsing
}
Write-Output ("rustup-init.exe = " + (Get-Item $init).Length + ' bytes')
# MinGW-w64 must be on PATH for the gnu toolchain's linker driver.
$envbin = 'C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt'
$env:PATH = "$envbin\Library\bin;$envbin\Library\x86_64-w64-mingw32\bin;$envbin\bin;$env:CARGO_HOME\bin;$env:PATH"
Write-Output ('gcc: ' + ((& gcc.exe --version | Select-Object -First 1)))
& $init --profile minimal --default-toolchain stable-x86_64-pc-windows-gnu --no-modify-path -y 2>&1 | Select-Object -Last 25
Write-Output ("rustup_exit=" + $LASTEXITCODE)
& "$env:CARGO_HOME\bin\rustc.exe" --version 2>&1
& "$env:CARGO_HOME\bin\cargo.exe" --version 2>&1
& "$env:CARGO_HOME\bin\rustup.exe" toolchain list 2>&1
Write-Output 'DONE'
