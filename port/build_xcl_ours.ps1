# Build OUR OWN XCL tree (main 64b3f35 + our two memory patches) in its own git worktree with
# its own CARGO_TARGET_DIR, so the agent testing upstream PRs keeps H:\leonida\xcl to itself.
# Provenance is exact and recorded: base commit + `git apply` of our saved patch, nothing else.
# Written as PowerShell, not batch: this file's LF line endings make cmd.exe mis-parse `rem`
# lines and multi-line `if ( )` blocks, which silently dropped every `set` on the first run.
$ErrorActionPreference = 'Continue'
$env:CARGO_HOME = 'H:\leonida\rust\cargo'
$env:RUSTUP_HOME = 'H:\leonida\rust\rustup'
$envbin = 'C:\Users\L.S\AppData\Local\miniforge3\envs\leonida-rt'
$env:PATH = "H:\leonida\rust\cargo\bin;$envbin\Library\bin;$envbin\Library\x86_64-w64-mingw32\bin;$envbin\bin;$env:PATH"
$env:CARGO_TARGET_DIR = 'H:\leonida\xcl-ours\target'
$env:HTTP_PROXY = 'http://127.0.0.1:7897'
$env:HTTPS_PROXY = 'http://127.0.0.1:7897'
$tree = 'H:\leonida\xcl-ours'
$exe = "$tree\target\release\xcl.exe"

if (-not (Test-Path "$tree\Cargo.toml")) {
    & git.exe -C 'H:\leonida\xcl' worktree add -f $tree 64b3f35 2>&1 | Select-Object -Last 3
    Write-Output ('worktree_exit=' + $LASTEXITCODE)
}
# The patch may already be applied from the earlier run; check before applying again.
$st = (& git.exe -C $tree status --porcelain) -join "`n"
Write-Output ('worktree status before build:' + $(if ($st) { "`n" + $st } else { ' clean' }))
if ($st -notmatch 'lazy\.rs') {
    & git.exe -C $tree apply --whitespace=fix 'H:\leonida\xcl-patch-mem.diff' 2>&1 | Select-Object -First 5
    Write-Output ('apply_exit=' + $LASTEXITCODE)
}

if (-not (Test-Path $exe)) {
    Set-Location $tree
    & "$env:CARGO_HOME\bin\cargo.exe" build --release --workspace --manifest-path "$tree\Cargo.toml" 1> 'H:\leonida\logs\ours_build.txt' 2>&1
    Write-Output ('build_exit=' + $LASTEXITCODE)
    Get-Content 'H:\leonida\logs\ours_build.txt' -Tail 14
} else {
    Write-Output ('exe already built: ' + (Get-Item $exe).Length + ' bytes, ' + (Get-Item $exe).LastWriteTime.ToString('HH:mm:ss'))
}

if (-not (Test-Path $exe)) { Write-Output 'NO EXE - stopping'; exit 1 }

# Archive the artifact plus its provenance, and the Agility/DXIL files it will load.
New-Item -ItemType Directory -Force -Path 'H:\leonida\bin\ours\D3D12' | Out-Null
Copy-Item $exe 'H:\leonida\bin\ours\xcl.exe' -Force
Copy-Item 'H:\leonida\agility\build\native\bin\x64\D3D12Core.dll' 'H:\leonida\bin\ours\D3D12\' -Force
Copy-Item 'H:\leonida\dxc\bin\x64\dxil.dll' 'H:\leonida\bin\ours\D3D12\' -Force
$head = (& git.exe -C $tree log -1 --format='%H %ci %s')
$st2 = (& git.exe -C $tree status --porcelain) -join "`n"
$sha = (Get-FileHash 'H:\leonida\bin\ours\xcl.exe' -Algorithm SHA256).Hash
@(
    'tree: H:\leonida\xcl-ours (git worktree of H:\leonida\xcl)'
    'base: ' + $head
    'patch: git apply H:\leonida\xcl-patch-mem.diff (lazy.rs + eh.rs + dxc.rs), nothing else'
    'toolchain: rustc/cargo 1.100.0 stable-x86_64-pc-windows-gnu, MinGW-w64 conda-forge gcc 16.2.0'
    'host: Windows 10 19045.3324, RTX 3080 20 GB (inbox D3D12 = SM 6.5, Agility cannot load)'
    'exe: ' + (Get-Item $exe).Length + ' bytes  sha256=' + $sha
    'git status --porcelain:'
    $st2
) | Set-Content 'H:\leonida\bin\ours\INFO.txt' -Encoding utf8
& git.exe -C $tree diff -- crates 1> 'H:\leonida\bin\ours\applied.diff' 2>&1
Write-Output ('archived: H:\leonida\bin\ours\xcl.exe  sha256=' + $sha.Substring(0, 16) + '...')
Write-Output ('applied.diff bytes: ' + (Get-Item 'H:\leonida\bin\ours\applied.diff').Length)
Write-Output 'DONE_OURS'
