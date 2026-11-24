# Poll the successor repo's Runtime CI run until its runtime-windows artifact is
# ready, then download and unpack it. Prints progress; exits 0 on success.
$ErrorActionPreference = 'Stop'
$tok = (Get-Content 'H:\leonida\token.txt' -Raw).Trim()   # gh auth token, cached at an ASCII path
$h = @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'leonida-compute' }
$R = 'https://api.github.com/repos/ubiquitarianism/leonida'
$runId = 45303583626          # Runtime workflow at head ff8ce388 (has f35d19cb SetThreadGroupAffinity)
$want = 'ff8ce38825bcd3f5fab377e19e8b582567670804'
$dst = 'H:\leonida\runtime-ci3'
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$deadline = (Get-Date).AddMinutes(75)
$aid = $null
while ((Get-Date) -lt $deadline) {
    try {
        $run = Invoke-RestMethod -Uri "$R/actions/runs/$runId" -Headers $h
        Write-Output ("$(Get-Date -Format HH:mm:ss) run status=" + $run.status + " conclusion=" + $run.conclusion + " head=" + $run.head_sha.Substring(0, 10))
        if ($run.status -eq 'completed') {
            $arts = Invoke-RestMethod -Uri "$R/actions/runs/$runId/artifacts" -Headers $h
            $a = $arts.artifacts | Where-Object { $_.name -eq 'runtime-windows' } | Select-Object -First 1
            if ($a) { $aid = $a.id; break }
            Write-Output "  no runtime-windows artifact in this run; scanning newest artifacts"
            $all = Invoke-RestMethod -Uri "$R/actions/artifacts?per_page=20" -Headers $h
            $a2 = $all.artifacts | Where-Object { $_.name -eq 'runtime-windows' -and -not $_.expired } | Select-Object -First 1
            if ($a2) { $aid = $a2.id; $run2 = Invoke-RestMethod -Uri "$R/actions/runs/$($a2.workflow_run.id)" -Headers $h; Write-Output ("  picked artifact #" + $aid + " head=" + $run2.head_sha.Substring(0,10)); break }
            Write-Output "  completed but no artifact yet; waiting"
        }
    } catch {
        Write-Output ("  poll ERR " + $_.Exception.Message)
    }
    Start-Sleep -Seconds 60
}
if (-not $aid) { Write-Output 'TIMEOUT waiting for the artifact'; exit 1 }

$zip = Join-Path $dst 'runtime-windows.zip'
Invoke-WebRequest -Uri "$R/actions/artifacts/$aid/zip" -Headers $h -OutFile $zip -UseBasicParsing
Write-Output ("downloaded bytes = " + (Get-Item $zip).Length)
Expand-Archive -Path $zip -DestinationPath (Join-Path $dst 'unzipped') -Force
$exe = Join-Path $dst 'unzipped\gta6rt.exe'
Write-Output ("gta6rt.exe = " + (Get-Item $exe).Length + " bytes, sha256 " + (Get-FileHash $exe -Algorithm SHA256).Hash)
$py = 'C:\Users\L.S\.dsh\dsh-runtimes\dsh-next-primary-runtime\dependencies\python\python.exe'
& $py -X utf8 -s -c "import re,sys;d=open(sys.argv[1],'rb').read();print('SetThreadGroupAffinity in binary:', b'SetThreadGroupAffinity' in d)" $exe
