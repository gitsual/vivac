<#
.SYNOPSIS
  A fake Ollama for tests/cases/Ask.Tests.ps1, on localhost only.

.DESCRIPTION
  Answers as Ollama does: /api/tags lists two models (none while the file
  empty exists in -State), /api/chat writes the request and its Host header
  into -State and streams NDJSON in chunks. The model name picks the
  behaviour: fake:1b streams three pieces, missing is a 404, stall waits four
  seconds before ending, broken sends an error line, anything else says one.
  Runs until the file stop appears in -State. A process of its own, as the
  bridge test runs its listener, so the test file holds no server code.
#>
param([int]$Port, [string]$State)
Set-StrictMode -Version 2.0
$utf8 = New-Object Text.UTF8Encoding $false
$http = New-Object Net.HttpListener
$http.Prefixes.Add("http://localhost:$Port/")
$http.Start()
[IO.File]::WriteAllText((Join-Path $State 'ready'), 'yes')

function Write-Line($Response, [string]$Line) {
    $b = $utf8.GetBytes($Line + "`n")
    $Response.OutputStream.Write($b, 0, $b.Length)
    $Response.OutputStream.Flush()
}
function Test-Flag([string]$Name) { Test-Path -LiteralPath (Join-Path $State $Name) }

while (-not (Test-Flag 'stop')) {
    $pending = $http.BeginGetContext($null, $null)
    while (-not $pending.AsyncWaitHandle.WaitOne(100)) { if (Test-Flag 'stop') { break } }
    if (Test-Flag 'stop') { break }
    $ctx = $http.EndGetContext($pending)
    $res = $ctx.Response
    try {
        [IO.File]::WriteAllText((Join-Path $State 'host'), [string]$ctx.Request.Headers['Host'])
        if ($ctx.Request.Url.AbsolutePath -eq '/api/tags') {
            $json = '{"models":[{"name":"fake:1b"},{"name":"other:7b"}]}'
            if (Test-Flag 'empty') { $json = '{"models":[]}' }
            $res.ContentType = 'application/json'
            Write-Line $res $json
            continue
        }
        $body = (New-Object IO.StreamReader($ctx.Request.InputStream, $utf8)).ReadToEnd()
        [IO.File]::WriteAllText((Join-Path $State 'request.json'), $body, $utf8)
        $model = ($body | ConvertFrom-Json).model
        if ($model -eq 'none') { $res.StatusCode = 404; Write-Line $res '{"error":"model ''none'' not found"}'; continue }
        if ($model -eq 'missing') { $res.StatusCode = 404; Write-Line $res '{"error":"model ''missing'' not found"}'; continue }
        $res.ContentType = 'application/x-ndjson'
        $res.SendChunked = $true
        $pieces = @('one')
        if ($model -eq 'fake:1b') { $pieces = @('Hel', 'lo ', ('w' + [char]0xF6 + 'rld')) }
        foreach ($piece in $pieces) { Write-Line $res (@{ model = $model; message = @{ role = 'assistant'; content = $piece }; done = $false } | ConvertTo-Json -Compress) }
        if ($model -eq 'stall') { Start-Sleep -Seconds 4 }
        if ($model -eq 'broken') { Write-Line $res '{"error":"the model crashed"}' }
        Write-Line $res '{"model":"x","message":{"role":"assistant","content":""},"done":true}'
    } catch {
    } finally { try { $res.Close() } catch { } }
}
$http.Stop()
