# The phone drop (lib/LocalSend.psm1, bin/vivac-localsend.ps1, docs/bridge.md
# at the product root, "Phones: LocalSend"): the PIN and its rate limit,
# prepare-upload read as data, and the receiver end to end on the loopback
# with requests made here as a LocalSend phone makes them, then the sender
# against it. A scratch profile; nothing reaches the screen
# (VIVAC_LOCALSEND_SINK), the Task Scheduler or the network.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('vivac-localsend-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$env:VIVAC_LOCALAPPDATA = Join-Path $scratch 'local'
$env:VIVAC_APPDATA = Join-Path $scratch 'roaming'
$env:VIVAC_LOCALSEND_SINK = Join-Path $scratch 'sink.txt'
$env:VIVAC_LINK_INBOX = Join-Path $scratch 'inbox'
$env:VIVAC_LOCALSEND_ALIAS = 'gate'
$env:VIVAC_LOCALSEND_INTERFACES = '127.0.0.1'
foreach ($d in $env:VIVAC_LOCALAPPDATA, $env:VIVAC_APPDATA) { [void](New-Item -ItemType Directory -Force -Path $d) }
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\LocalSend.psm1') -Force
Set-VivacSetting language en
$utf8 = New-Object Text.UTF8Encoding $false
$tool = Join-Path $root 'bin\vivac-localsend.ps1'

function Invoke-Drop([string[]]$DropArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool @DropArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
function Read-Sink {
    if (-not (Test-Path -LiteralPath $env:VIVAC_LOCALSEND_SINK)) { return '' }
    [IO.File]::ReadAllText($env:VIVAC_LOCALSEND_SINK)
}

Case 'the PIN: 401 without or wrong, 429 after five wrong a minute, per address' {
    $f = @{}
    Assert-Equal 401 (Test-VivacLocalSendPin $f 'a' '' '123456' 0)
    for ($i = 0; $i -lt 5; $i++) { Assert-Equal 401 (Test-VivacLocalSendPin $f 'a' '000000' '123456' $i) }
    Assert-Equal 429 (Test-VivacLocalSendPin $f 'a' '123456' '123456' 10)
    Assert-Equal 0 (Test-VivacLocalSendPin $f 'b' '123456' '123456' 10)
    Assert-Equal 0 (Test-VivacLocalSendPin $f 'a' '123456' '123456' 65) 'a minute later'
    Assert-Equal 401 (Test-VivacLocalSendPin $f 'c' 'anything' '' 0) 'no PIN set refuses everything'
}
Case 'the PIN is six random digits, kept; localsend_pin overrides it' {
    $pin = New-VivacLocalSendPin
    Assert-True ($pin -match '^\d{6}$') "pin: $pin"
    Assert-Equal $pin (New-VivacLocalSendPin)
    Assert-True ((New-VivacLocalSendPin -Again) -match '^\d{6}$')
    Set-VivacSetting localsend_pin 'Abc123'
    Assert-Equal 'Abc123' (Get-VivacLocalSendPin)
    Assert-Throws { Set-VivacSetting localsend_pin 'a b' } 'not a valid value'
    Set-VivacSetting localsend_pin 'auto'
}
Case 'prepare-upload is read as data: safe names, texts apart, sizes checked' {
    $p = Read-VivacLocalSendPrepare '{"info":{"alias":"Pixel\u0007"},"files":{"a":{"id":"a","fileName":"..\\..\\Windows\\con.txt","size":3,"fileType":"text/plain","sha256":"AB"},"t":{"id":"t","fileName":"t.txt","size":2,"fileType":"text/plain","preview":"hi"}}}'
    Assert-Equal 'Pixel' $p.Alias
    Assert-Equal '_con.txt' $p.Files['a'].Name
    Assert-Equal '' $p.Files['a'].Sha256 'a malformed sha256 is no sha256'
    Assert-Equal 'hi' (@($p.Texts) -join ',')
    Assert-Throws { Read-VivacLocalSendPrepare '{"files":{"b":{"id":"b","fileName":"b","size":2147483649,"fileType":"x"}}}' } 'status 413'
    Assert-Throws { Read-VivacLocalSendPrepare '{"files":{}}' } 'status 400'
    Assert-Throws { Read-VivacLocalSendPrepare 'nope' } 'status 400'
}
Case 'a device is what it announces, or nothing' {
    $d = ConvertTo-VivacLocalSendDevice ('{"alias":"Pixel","fingerprint":"ab","port":53317,"protocol":"https","deviceModel":"Google"}' | ConvertFrom-Json) '192.0.2.7'
    Assert-Equal 'Pixel (Google, 192.0.2.7)' (Format-VivacLocalSendDevice $d)
    Assert-Equal $null (ConvertTo-VivacLocalSendDevice ('{"alias":"x","fingerprint":"ab","protocol":"ftp"}' | ConvertFrom-Json) '192.0.2.7')
    Assert-Equal $null (ConvertTo-VivacLocalSendDevice ('{"alias":"x","fingerprint":"ab","port":70000}' | ConvertFrom-Json) '192.0.2.7')
    Assert-Equal $null (ConvertTo-VivacLocalSendDevice ('{"alias":"x"}' | ConvertFrom-Json) '192.0.2.7')
}

# ------------------------------------------------------------ end to end

$port = Get-Random -Minimum 40000 -Maximum 60000
$pin = New-VivacLocalSendPin
$receiver = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tool`"", '-Serve', '-Port', $port, '-Bind', '127.0.0.1', '-NoMulticast')
$api = Get-VivacLocalSendApi

# A request as a phone makes it, from a chosen loopback address.
function Send-Phone([string]$Method, [string]$Path, [byte[]]$Body, [string]$From = '127.0.0.1', [switch]$Chunked, [long]$Length = -1) {
    $client = New-Object Net.Sockets.TcpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($From), 0))
    try {
        $client.Connect('127.0.0.1', $port)
        $client.ReceiveTimeout = 20000
        $s = $client.GetStream()
        if ($null -eq $Body) { $Body = New-Object byte[] 0 }
        $head = "$Method $Path HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n"
        if ($Chunked) { $head += "Transfer-Encoding: chunked`r`n" }
        elseif ($Length -ge 0) { $head += "Content-Length: $Length`r`n" }
        else { $head += "Content-Length: $($Body.Length)`r`n" }
        $hb = $utf8.GetBytes("$head`r`n")
        $s.Write($hb, 0, $hb.Length)
        if ($Chunked) {
            for ($i = 0; $i -lt $Body.Length; $i += 3) {
                $n = [Math]::Min(3, $Body.Length - $i)
                $c = $utf8.GetBytes(('{0:x}' -f $n) + "`r`n"); $s.Write($c, 0, $c.Length)
                $s.Write($Body, $i, $n)
                $c = $utf8.GetBytes("`r`n"); $s.Write($c, 0, $c.Length)
            }
            $c = $utf8.GetBytes("0`r`n`r`n"); $s.Write($c, 0, $c.Length)
        } elseif ($Length -lt 0) { $s.Write($Body, 0, $Body.Length) }
        Read-VivacLocalSendResponse $s
    } finally { $client.Close() }
}
function Get-Status([string]$Method, [string]$Path, [string]$Json = '', [string]$From = '127.0.0.1') {
    $b = $null
    if ($Json) { $b = $utf8.GetBytes($Json) }
    (Send-Phone $Method $Path $b $From).Status
}
$phone = '"info":{"alias":"Pixel","version":"2.1","deviceModel":"Google","deviceType":"mobile","fingerprint":"phone-1","port":53317,"protocol":"https","download":false}'
$payload = $utf8.GetBytes("payload`n")
$payloadSha = Get-VivacLocalSendSha256 $payload
$one = "{$phone,`"files`":{`"f1`":{`"id`":`"f1`",`"fileName`":`"a.txt`",`"size`":8,`"fileType`":`"text/plain`",`"sha256`":`"$payloadSha`",`"preview`":null}}}"
$inbox = $env:VIVAC_LINK_INBOX

try {
    # A loaded machine takes a while to start a PowerShell and its modules.
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ($receiver.HasExited) { break }
        try { [void](Send-Phone 'GET' "$api/info" $null); break } catch { Start-Sleep -Milliseconds 250 }
    }

    Case 'receiver: /info and /register say who this is' {
        $logFile = Join-Path (Get-VivacPaths).State 'localsend.log'
        $said = ''
        if (Test-Path -LiteralPath $logFile) { $said = [IO.File]::ReadAllText($logFile) }
        Assert-True (-not $receiver.HasExited) "the receiver stopped: $said"
        $r = Send-Phone 'GET' "$api/info" $null
        Assert-Equal 200 $r.Status
        $i = $r.Body | ConvertFrom-Json
        Assert-Equal 'gate' $i.alias
        Assert-Equal 'http' $i.protocol
        Assert-Equal 'desktop' $i.deviceType
        Assert-True ($i.version -like '2.*') "version $($i.version)"
        Assert-Equal 200 (Get-Status 'POST' "$api/register" '{"alias":"Pixel","fingerprint":"phone-1","port":53317,"protocol":"https"}')
        Assert-True ([IO.File]::ReadAllText((Get-VivacLocalSendDevicesPath)) -match 'Pixel') 'the phone is remembered for the sender'
    }
    Case 'receiver: the PIN, then too many wrong ones from one address' {
        Assert-Equal 401 (Get-Status 'POST' "$api/prepare-upload" $one)
        for ($i = 0; $i -lt 5; $i++) { Assert-Equal 401 (Get-Status 'POST' "$api/prepare-upload?pin=000000" $one '127.0.0.2') }
        Assert-Equal 429 (Get-Status 'POST' "$api/prepare-upload?pin=$pin" $one '127.0.0.2')
        $r = Send-Phone 'POST' "$api/prepare-upload?pin=$pin" $utf8.GetBytes($one) '127.0.0.3'
        Assert-Equal 200 $r.Status 'another address is not locked out'
        Assert-Equal 200 (Get-Status 'POST' "$api/cancel?sessionId=$(($r.Body | ConvertFrom-Json).sessionId)" '' '127.0.0.3')
    }
    Case 'receiver: tokens, addresses, names, sha256, never overwriting, one card per batch' {
        $batch = "{$phone,`"files`":{" +
        "`"k`":{`"id`":`"k`",`"fileName`":`"../../.ssh/authorized_keys`",`"size`":8,`"fileType`":`"text/plain`",`"sha256`":`"$payloadSha`"}," +
        "`"c`":{`"id`":`"c`",`"fileName`":`"..\\..\\Windows\\con`",`"size`":8,`"fileType`":`"application/octet-stream`"}," +
        "`"w`":{`"id`":`"w`",`"fileName`":`"wrong.bin`",`"size`":6,`"fileType`":`"application/octet-stream`",`"sha256`":`"$payloadSha`"}}}"
        $r = Send-Phone 'POST' "$api/prepare-upload?pin=$pin" $utf8.GetBytes($batch)
        Assert-Equal 200 $r.Status $r.Body
        $a = $r.Body | ConvertFrom-Json
        $sid = $a.sessionId
        $up = { param($id, $tok) "$api/upload?sessionId=$sid&fileId=$id&token=$tok" }
        Assert-Equal 403 (Send-Phone 'POST' (& $up 'k' $a.files.c) $payload).Status 'a token of another file'
        Assert-Equal 403 (Send-Phone 'POST' (& $up 'k' $a.files.k) $payload '127.0.0.3').Status 'another address'
        Assert-Equal 400 (Send-Phone 'POST' "$api/upload?sessionId=$sid&fileId=k" $payload).Status 'no token'
        Assert-Equal 409 (Get-Status 'POST' "$api/prepare-upload?pin=$pin" $one '127.0.0.3') 'a second sender while a session runs'
        Assert-Equal 200 (Send-Phone 'POST' (& $up 'k' $a.files.k) $payload).Status
        Assert-Equal 403 (Send-Phone 'POST' (& $up 'k' $a.files.k) $payload).Status 'the same file twice'
        Assert-Equal 200 (Send-Phone 'POST' (& $up 'c' $a.files.c) $payload -Chunked).Status 'chunked'
        Assert-Equal 422 (Send-Phone 'POST' (& $up 'w' $a.files.w) $utf8.GetBytes("other`n")).Status 'sha256 mismatch'
        Assert-True (Test-Path -LiteralPath (Join-Path $inbox 'authorized_keys')) 'the name without its folders'
        Assert-True (Test-Path -LiteralPath (Join-Path $inbox '_con')) 'a device name made safe'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $inbox 'wrong.bin'))) 'a refused file is not kept'
        Assert-Equal 2 @(Get-ChildItem -LiteralPath $inbox -Force).Count 'no part file left behind'
        Assert-Equal '' (Read-Sink) 'no card before the batch is over'
        Assert-Equal 200 (Get-Status 'POST' "$api/cancel?sessionId=$sid")
        Assert-True ((Read-Sink) -match "2 files from Pixel: click to open the folder\|.*inbox\|.*inbox") (Read-Sink)
    }
    Case 'receiver: 413 past 2 GiB or past the announced size; a text is only a card' {
        $big = "{$phone,`"files`":{`"b`":{`"id`":`"b`",`"fileName`":`"big.iso`",`"size`":2147483649,`"fileType`":`"application/octet-stream`"}}}"
        Assert-Equal 413 (Get-Status 'POST' "$api/prepare-upload?pin=$pin" $big)
        $a = (Send-Phone 'POST' "$api/prepare-upload?pin=$pin" $utf8.GetBytes($one)).Body | ConvertFrom-Json
        Assert-Equal 413 (Send-Phone 'POST' "$api/upload?sessionId=$($a.sessionId)&fileId=f1&token=$($a.files.f1)" $null -Length 9000000000).Status
        Assert-Equal 200 (Send-Phone 'POST' "$api/upload?sessionId=$($a.sessionId)&fileId=f1&token=$($a.files.f1)" $payload).Status
        Assert-True ((Read-Sink) -match 'Pixel sent a\.txt') (Read-Sink)
        $text = "{$phone,`"files`":{`"t`":{`"id`":`"t`",`"fileName`":`"t.txt`",`"size`":5,`"fileType`":`"text/plain`",`"preview`":`"hola `$(id)`"}}}"
        Assert-Equal 204 (Get-Status 'POST' "$api/prepare-upload?pin=$pin" $text)
        Assert-True ((Read-Sink) -match 'Text from Pixel\|hola \$\(id\)\|') (Read-Sink)
        Assert-Equal 3 @(Get-ChildItem -LiteralPath $inbox -Force).Count 'a text is not written'
        Assert-Equal 404 (Get-Status 'GET' '/api/localsend/v1/info')
    }
    Case 'sender: a file and a text to the receiver, by address' {
        $src = Join-Path $scratch 'a.txt'
        [IO.File]::WriteAllText($src, "from the pc`n")
        $env:VIVAC_LOCALSEND_ALIAS = 'laptop'
        $saved = $env:VIVAC_LOCALAPPDATA
        $env:VIVAC_LOCALAPPDATA = Join-Path $scratch 'sender'
        try { $r = Invoke-Drop @('send', $src, '-Text', 'a note', '-Peer', "127.0.0.1:$port", '-Pin', $pin) }
        finally { $env:VIVAC_LOCALSEND_ALIAS = 'gate'; $env:VIVAC_LOCALAPPDATA = $saved }
        Assert-Equal 0 $r.Code $r.Text
        Assert-True ($r.Text -match 'Sent 2 to gate') $r.Text
        Assert-Equal "from the pc`n" ([IO.File]::ReadAllText((Join-Path $inbox 'a (2).txt')))
        Assert-True ((Read-Sink) -match 'Text from laptop\|a note\|') (Read-Sink)
        $r = Invoke-Drop @('send', $src, '-Peer', "127.0.0.1:$port")
        Assert-True ($r.Code -ne 0 -and $r.Text -match 'asks for a PIN') $r.Text
    }
    Case 'on, off and status (the task is a file beside the sink here)' {
        $r = Invoke-Drop @('toggle')
        Assert-True ($r.Text -match "Phone drop is on.*PIN: $pin") $r.Text
        Assert-True (Test-Path -LiteralPath "$($env:VIVAC_LOCALSEND_SINK).task")
        Assert-True ((Invoke-Drop @('status')).Text -match "Phone drop: on[\s\S]*PIN: $pin") 'status'
        Assert-True ((Invoke-Drop @('toggle')).Text -match 'Phone drop is off')
        Assert-True (-not (Test-Path -LiteralPath "$($env:VIVAC_LOCALSEND_SINK).task"))
    }
} finally {
    if ($receiver -and -not $receiver.HasExited) { Stop-Process -Id $receiver.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Cases
