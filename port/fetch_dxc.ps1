# DX Compiler for XCL: XCL needs dxcompiler.dll + dxil.dll (README line 94-108).
# DXC 1.9.2609 is the release the XCL issue reporters used, and 1.7's DXIL costs
# 2-2.7x the size and 1.4-2.2x the driver pipeline time (#156), so take 1.9.
$ErrorActionPreference = 'Stop'
$Proxy = 'http://127.0.0.1:7897'
$zip = 'H:\leonida\dxc_1_9_2609.zip'
$dst = 'H:\leonida\dxc'
$url = 'https://github.com/microsoft/DirectXShaderCompiler/releases/download/v1.9.2609/dxc_2026_09_29.zip'
$want = 'ad31b1fc8443175d204f77a611fdb3ef2ec42759bdc2f1167368de24a4a7e7f1'   # digest from the release API
if (-not (Test-Path $zip)) {
    Write-Output 'downloading dxc_2026_09_29.zip (32 MB)'
    Invoke-WebRequest -Uri $url -OutFile $zip -Proxy $Proxy -UseBasicParsing
}
$got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Write-Output ("zip sha256 " + $got)
if ($got -ne $want) { Write-Output 'HASH MISMATCH'; exit 1 }
if (-not (Test-Path $dst)) {
    Write-Output 'extracting'
    Expand-Archive -Path $zip -DestinationPath $dst -Force
}
foreach ($f in 'bin\x64\dxcompiler.dll', 'bin\x64\dxil.dll', 'bin\x64\dxc.exe') {
    $p = Join-Path $dst $f
    if (Test-Path $p) { Write-Output ("OK  " + $p + "  " + (Get-Item $p).Length) } else { Write-Output ("MISSING " + $p) }
}
Write-Output 'DXC_READY'
