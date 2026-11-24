# Post the drafted #488 test report. It adds one thing no existing comment has: the PR's new
# job-object test fails 3/3 when run with --exact on a machine with NO memory pressure
# (64 GB RAM, 153 GB commit limit, 125 GB commit free), which separates "the machine is out of
# commit" from "the test itself is unstable" - the same symptom futurepro62 saw on MSVC/Win11.
$ErrorActionPreference = 'Stop'
$tok = (Get-Content 'H:\leonida\token.txt' -Raw).Trim()
$body = Get-Content 'H:\leonida\prtest\comment488.md' -Raw -Encoding UTF8
if ($body -match 'GTA|Rockstar') { Write-Output 'ABORT: the draft names the title'; exit 1 }
$h = @{
    Authorization = "Bearer $tok"
    Accept        = 'application/vnd.github+json'
    'User-Agent'  = 'leonida-field-notes'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$json = @{ body = $body } | ConvertTo-Json -Depth 4
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$r = Invoke-RestMethod -Uri 'https://api.github.com/repos/ivall/xcl/issues/488/comments' -Method Post -Headers $h -Body $bytes -ContentType 'application/json;charset=utf-8'
Write-Output ('posted: ' + $r.html_url)
Write-Output ('body bytes: ' + $bytes.Length)
