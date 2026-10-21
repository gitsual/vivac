<#
.SYNOPSIS
  The phone drop: LocalSend on the Windows side, receiving and sending.

.DESCRIPTION
  A phone with the stock LocalSend app sends files and texts here and gets
  them from here, with no vivac app on it (docs/bridge.md at the product
  root, "Phones: LocalSend"). This side serves plain http on TCP 53317, so
  phones send to it over http; it sends to phones over what they announce,
  https with a self-signed certificate as a rule, and only once that
  certificate's SHA-256 is the fingerprint the phone announced.

    send FILE...      send files (-Text TEXT for a text; -To ALIAS, or
                      -Peer HOST:PORT when discovery does not get through;
                      -Pin PIN when the phone asks for one)
    pick              choose files, then a phone (the menu's "Send to phone")
    devices           what answers LocalSend on this network
    status            on or off, the PIN, where files go
    on | off          start or stop receiving (the sign-in task \vivac\localsend)
    toggle            on when off, off when on (the menu's "Phone drop")
    pin [-New]        print the PIN, or make a new one

    -Serve       receive (what the sign-in task runs; -Port, -Bind, -NoMulticast)
    -Register    run -Serve at every sign-in, as \vivac\localsend, and start it
    -Unregister  remove that task and stop the receiver

  Receiving needs the PIN: localsend_pin in the settings, else the six
  random digits made when it is first turned on. Without it 401; five
  wrong ones in a minute from one address, 429. Files go into
  Downloads\vivac-link under a safe name, never over another file; a text is
  shown in a card and goes nowhere else. Phones reach it only through the
  firewall rule `apply-system.ps1 -LocalSend` adds: private networks, local
  subnet, TCP and UDP 53317.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Verb,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest,
    [string]$To,
    [string]$Peer,
    [string]$Pin,
    [string[]]$Text,
    [switch]$New,
    [switch]$Serve,
    [int]$Port = -1,
    [string]$Bind = '',
    [switch]$NoMulticast,
    [switch]$Register,
    [switch]$Unregister,
    # Say how it went in a card, not on a console (the menu runs without one).
    [switch]$Notify,
    # A card the receiver asked for, shown by a process of its own so the
    # receiver never waits on a window.
    [string]$Card
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Bridge.psm1') -Force
Import-Module (Join-Path $root 'lib\LocalSend.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

$paths = Get-VivacPaths
$log = Join-Path $paths.State 'localsend.log'
$cards = Join-Path $paths.State 'localsend-cards'
$taskPath = '\vivac\'
$taskName = 'localsend'
$utf8 = New-Object Text.UTF8Encoding $false
$api = Get-VivacLocalSendApi
# The gates set VIVAC_LOCALSEND_SINK to a file: what would reach the screen
# is a line there ("title|body|folder"), and the sign-in task is a file beside it.
$sink = $env:VIVAC_LOCALSEND_SINK

function Write-DropLog([string]$Line) {
    try {
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $log))
        Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Line) -Encoding UTF8
    } catch { }
}

# ------------------------------------------------------------------- cards

if ($Card) {
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    Import-Module (Join-Path $root 'lib\Toasts.psm1') -Force
    $c = [IO.File]::ReadAllText($Card, $utf8) | ConvertFrom-Json
    Remove-Item -LiteralPath $Card -Force -ErrorAction SilentlyContinue
    $click = $null
    if ($c.open) { $target = [string]$c.open; $click = { Start-Process explorer.exe -ArgumentList "`"$target`"" }.GetNewClosure() }
    Show-VivacToast ([string]$c.title) ([string]$c.body) 'vivac' '' '' $click
    # Until the card is gone: clicked, closed, or timed out.
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $t.Add_Tick({ if (-not (& (Get-Module Toasts) { $script:Stack.Count })) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } })
    $t.Start()
    [Windows.Threading.Dispatcher]::Run()
    return
}

# A card; with $Open, a click opens that folder. Never opens anything itself.
function Show-DropCard([string]$Title, [string]$Body, [string]$Open = '') {
    if ($sink) { Add-Content -LiteralPath $sink -Value (("$Title|$Body|$Open") -replace "`r", '') -Encoding UTF8; return }
    [void](New-Item -ItemType Directory -Force -Path $cards)
    $file = Join-Path $cards ([guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($file, (@{ title = $Title; body = $Body; open = $Open } | ConvertTo-Json -Compress), $utf8)
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Card', "`"$file`"")
}

# ------------------------------------------------------------------- task

function Test-DropOn {
    if ($sink) { return (Test-Path -LiteralPath "$sink.task") }
    [bool](Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue)
}

if ($Unregister) {
    if ($sink) { Remove-Item -LiteralPath "$sink.task" -Force -ErrorAction SilentlyContinue; "removed $taskPath$taskName"; return }
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'vivac-localsend\.ps1' -and $_.CommandLine -match '-Serve' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    "removed $taskPath$taskName"
    return
}

if ($Register) {
    [void](New-VivacLocalSendPin)
    if ($sink) { Set-Content -LiteralPath "$sink.task" -Value 'on'; "registered $taskPath$taskName (Logon) and started it"; return }
    $runner = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Serve"
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $runner
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settingsObj = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settingsObj -Force | Out-Null
    Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    "registered $taskPath$taskName (Logon) and started it"
    return
}

# ------------------------------------------------------------------ server

# Refusals travel as exceptions 'status NNN: reason' up to the connection.
function Stop-Request([int]$Status, [string]$Reason) { throw "status ${Status}: $Reason" }

# The request line and headers, bounded: 16 KiB.
function Read-DropRequest([IO.Stream]$Stream) {
    $first = Read-VivacLocalSendLine $Stream
    if (-not $first) { return $null }
    if ($first -notmatch '^([A-Z]+) (\S+) HTTP/1\.[01]$') { Stop-Request 400 'not HTTP' }
    $method = $Matches[1]; $target = $Matches[2]
    $headers = @{}
    $size = 0
    while ($true) {
        $l = Read-VivacLocalSendLine $Stream
        if (-not $l) { break }
        $size += $l.Length
        if ($size -gt 16KB) { Stop-Request 431 'headers too large' }
        $i = $l.IndexOf(':')
        if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() }
    }
    $path = $target; $query = @{}
    $q = $target.IndexOf('?')
    if ($q -ge 0) {
        $path = $target.Substring(0, $q)
        foreach ($pair in $target.Substring($q + 1) -split '&') {
            $kv = $pair -split '=', 2
            if ($kv.Count -eq 2 -and $kv[0]) { $query[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
        }
    }
    [pscustomobject]@{ Method = $method; Path = $path; Query = $query; Headers = $headers }
}

# The body, to $Sink (a stream) and through $Sha when given, by Content-Length
# or chunked transfer: 413 as soon as it passes $Limit, 400 when it ends early.
function Copy-DropBody($Request, [IO.Stream]$Stream, [IO.Stream]$Sink, [long]$Limit, $Sha) {
    $buffer = New-Object byte[] 1MB
    $total = 0L
    $copy = {
        param([long]$Count)
        while ($Count -gt 0) {
            $n = $Stream.Read($buffer, 0, [int][Math]::Min($Count, $buffer.Length))
            if ($n -le 0) { Stop-Request 400 'short body' }
            $Sink.Write($buffer, 0, $n)
            if ($Sha) { [void]$Sha.TransformBlock($buffer, 0, $n, $null, 0) }
            $Count -= $n
        }
    }
    if ([string]$Request.Headers['transfer-encoding'] -match 'chunked') {
        while ($true) {
            $sizeText = ((Read-VivacLocalSendLine $Stream) -split ';')[0].Trim()
            $size = 0L
            try { $size = [Convert]::ToInt64($sizeText, 16) } catch { Stop-Request 400 'bad chunk' }
            if ($size -eq 0) { while (Read-VivacLocalSendLine $Stream) { }; break }
            $total += $size
            if ($total -gt $Limit) { Stop-Request 413 'too large' }
            & $copy $size
            [void](Read-VivacLocalSendLine $Stream)
        }
        return $total
    }
    $length = 0L
    if (-not [long]::TryParse([string]$Request.Headers['content-length'], [ref]$length) -or $length -lt 0) { Stop-Request 411 'length required' }
    if ($length -gt $Limit) { Stop-Request 413 'too large' }
    & $copy $length
    $length
}

function Read-DropJson($Request, [IO.Stream]$Stream) {
    $m = New-Object IO.MemoryStream
    [void](Copy-DropBody $Request $Stream $m (Get-VivacLocalSendJsonLimit) $null)
    $utf8.GetString($m.ToArray())
}

function Write-DropResponse([IO.Stream]$Stream, [int]$Status, [string]$Json = '') {
    $reasons = @{ 200 = 'OK'; 204 = 'No Content'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 409 = 'Conflict'; 411 = 'Length Required'; 413 = 'Payload Too Large'; 422 = 'Unprocessable Entity'; 429 = 'Too Many Requests'; 431 = 'Request Header Fields Too Large'; 500 = 'Internal Server Error' }
    $bytes = $utf8.GetBytes($Json)
    $head = "HTTP/1.1 $Status $($reasons[$Status])`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n"
    if ($bytes.Length) { $head += "Content-Type: application/json`r`n" }
    $hb = $utf8.GetBytes("$head`r`n")
    $Stream.Write($hb, 0, $hb.Length)
    if ($bytes.Length) { $Stream.Write($bytes, 0, $bytes.Length) }
}

# One card per batch, with a click that opens the folder.
function Show-DropBatch($Session) {
    $received = @($Session.Received)
    if (-not $received.Count) { return }
    $folder = Split-Path -Parent $received[0]
    if ($received.Count -eq 1) { $title = T 'localsend.received_one' @($Session.Sender, (Split-Path -Leaf $received[0])) }
    else { $title = T 'localsend.received_many' @($received.Count, $Session.Sender) }
    Show-DropCard $title $folder $folder
}

$script:Session = $null
$script:Failures = @{}

function Invoke-DropPrepare($Request, [IO.Stream]$Stream, [string]$Address) {
    $why = Test-VivacLocalSendPin $script:Failures $Address ([string]$Request.Query['pin']) (Get-VivacLocalSendPin)
    if ($why -eq 429) { Stop-Request 429 'too many wrong PINs' }
    if ($why -eq 401) { Stop-Request 401 'PIN required or wrong' }
    $json = Read-DropJson $Request $Stream
    try { $p = Read-VivacLocalSendPrepare $json } catch { if ($_.Exception.Message -match '^status \d{3}') { throw } ; Stop-Request 400 'malformed' }
    $who = $p.Alias
    if (-not $who) { $who = T 'localsend.someone' }
    foreach ($t in $p.Texts) { Show-DropCard (T 'localsend.text_from' @($who)) (Format-VivacLocalSendText $t) }
    if (-not $p.Files.Count) { return @(204, '') }
    $old = $script:Session
    if ($old -and $old.Address -ne $Address -and ((Get-Date) - $old.Touched).TotalSeconds -lt 300) { Stop-Request 409 'another session is running' }
    if ($old) { Show-DropBatch $old }
    $script:Session = [pscustomobject]@{ Id = New-VivacLocalSendToken; Address = $Address; Sender = $who; Files = $p.Files; Received = (New-Object Collections.ArrayList); Touched = (Get-Date) }
    $tokens = [ordered]@{}
    foreach ($k in $p.Files.Keys) { $tokens[$k] = $p.Files[$k].Token }
    @(200, (ConvertTo-VivacLocalSendJson ([ordered]@{ sessionId = $script:Session.Id; files = $tokens })))
}

# The upload streamed into a hidden part file in the inbox, checked, then
# moved to a free name: the inbox never holds half a file under a real name.
# 422 when the SHA-256 differs, 413 past the announced size; the part file
# goes either way.
function Invoke-DropUpload($Request, [IO.Stream]$Stream, [string]$Address) {
    $q = $Request.Query
    if (-not $q['sessionId'] -or -not $q['fileId'] -or -not $q['token']) { Stop-Request 400 'missing parameters' }
    $s = $script:Session
    if (-not $s -or -not (Test-VivacLocalSendSame $s.Id ([string]$q['sessionId'])) -or $s.Address -ne $Address) { Stop-Request 403 'no such session from this address' }
    $id = [string]$q['fileId']
    if (-not $s.Files.Contains($id)) { Stop-Request 403 'bad token' }
    $f = $s.Files[$id]
    if ($f.Done -or -not (Test-VivacLocalSendSame $f.Token ([string]$q['token']))) { Stop-Request 403 'bad token' }
    $s.Touched = Get-Date
    $inbox = Get-VivacLinkInbox
    [void](New-Item -ItemType Directory -Force -Path $inbox)
    $part = Join-Path $inbox ('.localsend-' + (New-VivacLocalSendToken).Substring(0, 16) + '.part')
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $out = New-Object IO.FileStream ($part, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try {
            (Get-Item -LiteralPath $part).Attributes = 'Hidden'
            $written = Copy-DropBody $Request $Stream $out ([Math]::Min($f.Size, (Get-VivacLocalSendFileLimit))) $sha
        } finally { $out.Dispose() }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        if ($written -ne $f.Size) { Stop-Request 400 'size differs from the one announced' }
        $digest = -join @($sha.Hash | ForEach-Object { $_.ToString('x2') })
        if ($f.Sha256 -and -not (Test-VivacLocalSendSame $digest $f.Sha256)) { Stop-Request 422 'sha256 mismatch' }
        (Get-Item -LiteralPath $part -Force).Attributes = 'Normal'
        while ($true) {
            $dest = Get-VivacFreePath $inbox $f.Name
            try { [IO.File]::Move($part, $dest); break } catch { if (-not (Test-Path -LiteralPath $dest)) { throw } }
        }
    } finally {
        $sha.Dispose()
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }
    $f.Done = $true
    [void]$s.Received.Add($dest)
    Write-DropLog "$Address sent $(Split-Path -Leaf $dest) ($($f.Size) bytes)"
    $allDone = $true
    foreach ($k in $s.Files.Keys) { if (-not $s.Files[$k].Done) { $allDone = $false } }
    if ($allDone) { $script:Session = $null; Show-DropBatch $s }
}

function Invoke-DropConnection([Net.Sockets.TcpClient]$Client, [int]$HttpPort) {
    $Client.ReceiveTimeout = 30000; $Client.SendTimeout = 30000
    $stream = $Client.GetStream()
    $address = $Client.Client.RemoteEndPoint.Address.ToString()
    $route = ''
    try {
        $req = Read-DropRequest $stream
        if (-not $req) { return }
        $route = "$($req.Method) $($req.Path)"
        switch ($route) {
            "GET $api/info" { Write-DropResponse $stream 200 (ConvertTo-VivacLocalSendJson (Get-VivacLocalSendInfo $HttpPort)) }
            "POST $api/register" {
                try { $d = ConvertTo-VivacLocalSendDevice ((Read-DropJson $req $stream) | ConvertFrom-Json) $address } catch { $d = $null }
                if ($d -and $d.Fingerprint -ne (Get-VivacLocalSendFingerprint)) { Add-VivacLocalSendDevice $d }
                Write-DropResponse $stream 200 (ConvertTo-VivacLocalSendJson (Get-VivacLocalSendInfo $HttpPort))
            }
            "POST $api/prepare-upload" {
                $answer = Invoke-DropPrepare $req $stream $address
                Write-DropResponse $stream $answer[0] $answer[1]
            }
            "POST $api/upload" { Invoke-DropUpload $req $stream $address; Write-DropResponse $stream 200 }
            "POST $api/cancel" {
                $s = $script:Session
                if ($s -and $req.Query['sessionId'] -and (Test-VivacLocalSendSame $s.Id ([string]$req.Query['sessionId'])) -and $s.Address -eq $address) {
                    $script:Session = $null
                    Show-DropBatch $s
                }
                Write-DropResponse $stream 200
            }
            default { Write-DropResponse $stream 404 '{"message":"not found"}' }
        }
    } catch {
        $m = $_.Exception.Message
        $status = 500
        if ($m -match '^status (\d{3}): (.*)$') { $status = [int]$Matches[1]; $m = $Matches[2] }
        Write-DropLog "refused $status $route from ${address}: $m"
        try { Write-DropResponse $stream $status (ConvertTo-VivacLocalSendJson @{ message = $m }) } catch { }
    } finally {
        # A request refused before its body was read still has it on the way:
        # closing on it would reset the connection and lose the answer. The
        # rest is read and dropped, a megabyte and a second at most.
        try {
            $Client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
            $Client.ReceiveTimeout = 1000
            $drop = New-Object byte[] 65536
            $total = 0
            while ($total -lt 1MB) { $n = $stream.Read($drop, 0, $drop.Length); if ($n -le 0) { break }; $total += $n }
        } catch { }
        $Client.Close()
    }
}

# Answers an announcement: register by HTTP, the preferred way, else a UDP
# answer in the group. What is heard is remembered for the sender.
function Receive-DropDatagrams([Net.Sockets.UdpClient]$Udp, [int]$HttpPort) {
    $own = Get-VivacLocalSendFingerprint
    while ($Udp.Available -gt 0) {
        $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
        $bytes = $Udp.Receive([ref]$ep)
        try { $m = $utf8.GetString($bytes) | ConvertFrom-Json } catch { continue }
        $d = ConvertTo-VivacLocalSendDevice $m $ep.Address.ToString()
        if (-not $d -or $d.Fingerprint -eq $own) { continue }
        Add-VivacLocalSendDevice $d
        # v1 called it "announcement"; both mean "answer me".
        $wants = ($m.PSObject.Properties['announce'] -and $m.announce -eq $true) -or ($m.PSObject.Properties['announcement'] -and $m.announcement -eq $true)
        if (-not $wants) { continue }
        $ok = $false
        try { $ok = (Invoke-VivacLocalSendHttp $d 'POST' "$api/register" $utf8.GetBytes((ConvertTo-VivacLocalSendJson (Get-VivacLocalSendInfo $HttpPort))) -TimeoutMs 2000).Status -eq 200 } catch { }
        if (-not $ok) { Send-VivacLocalSendShout (Get-VivacLocalSendInfo $HttpPort -Announce $false) }
    }
}

if ($Serve) {
    [void](New-VivacLocalSendPin)
    $httpPort = Get-VivacLocalSendPort
    if ($Port -ge 0) { $httpPort = $Port }
    $address = [Net.IPAddress]::Any
    if ($Bind) { $address = [Net.IPAddress]::Parse($Bind) }
    $listener = New-Object Net.Sockets.TcpListener ($address, $httpPort)
    $listener.Start()
    $httpPort = $listener.LocalEndpoint.Port
    $udp = $null
    if (-not $NoMulticast) {
        $udp = New-VivacLocalSendMulticast
        if ($udp) { Send-VivacLocalSendShout (Get-VivacLocalSendInfo $httpPort -Announce $true) }
        else { Write-DropLog 'cannot join the LocalSend group: discovery is off' }
    }
    Write-DropLog "listening on $httpPort (http, pid $PID)"
    "listening on ${httpPort}"
    while ($true) {
        try {
            if ($listener.Pending()) { Invoke-DropConnection $listener.AcceptTcpClient() $httpPort }
            if ($udp) { Receive-DropDatagrams $udp $httpPort }
        } catch {
            Write-DropLog "loop: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 30
    }
}

# ------------------------------------------------------------------ sender

# What is sent: a file from disk, or a text, which LocalSend carries as a .txt
# whose preview is the text.
function New-DropItem([string]$Path, [string]$TextBody) {
    $id = (New-VivacLocalSendToken).Substring(0, 16)
    if ($Path) {
        Add-Type -AssemblyName System.Web
        $item = Get-Item -LiteralPath $Path
        return [pscustomobject]@{ Id = $id; Name = $item.Name; Size = $item.Length; Type = [Web.MimeMapping]::GetMimeMapping($item.Name); Sha = (Get-VivacLocalSendFileSha256 $item.FullName); Path = $item.FullName; Text = $null; Modified = $item.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    }
    $bytes = $utf8.GetBytes($TextBody)
    [pscustomobject]@{ Id = $id; Name = "$id.txt"; Size = $bytes.Length; Type = 'text/plain'; Sha = (Get-VivacLocalSendSha256 $bytes); Path = $null; Text = $TextBody; Modified = $null }
}

# prepare-upload (the phone may ask its owner first: up to five minutes),
# then each file the phone took, streamed. Returns how many arrived.
function Send-DropItems($Device, [object[]]$Items, [string]$GivenPin) {
    $files = [ordered]@{}
    foreach ($i in $Items) {
        $e = [ordered]@{ id = $i.Id; fileName = $i.Name; size = $i.Size; fileType = $i.Type; sha256 = $i.Sha; preview = $i.Text }
        if ($i.Modified) { $e['metadata'] = [ordered]@{ modified = $i.Modified; accessed = $i.Modified } }
        $files[$i.Id] = $e
    }
    $body = $utf8.GetBytes((ConvertTo-VivacLocalSendJson ([ordered]@{ info = (Get-VivacLocalSendInfo); files = $files })))
    $path = "$api/prepare-upload"
    if ($GivenPin) { $path += '?pin=' + [Uri]::EscapeDataString($GivenPin) }
    try { $r = Invoke-VivacLocalSendHttp $Device 'POST' $path $body -TimeoutMs 300000 }
    catch {
        if ($_.Exception.Message -like 'untrusted*') { throw (T 'localsend.untrusted' @(Format-VivacLocalSendDevice $Device)) }
        throw (T 'localsend.unreachable' @((Format-VivacLocalSendDevice $Device), $_.Exception.Message))
    }
    if ($r.Status -eq 204) { return $Items.Count }
    if ($r.Status -eq 401 -and -not $GivenPin) { throw (T 'localsend.needs_pin' @($Device.Alias)) }
    $reasons = @{ 401 = 'localsend.refused_pin'; 403 = 'localsend.refused'; 409 = 'localsend.busy'; 429 = 'localsend.refused_tries' }
    if ($r.Status -ne 200) {
        if ($reasons.ContainsKey($r.Status)) { throw (T $reasons[$r.Status] @($Device.Alias)) }
        throw (T 'localsend.refused_other' @($Device.Alias, $r.Status))
    }
    $answer = $r.Body | ConvertFrom-Json
    $session = [string]$answer.sessionId
    $tokens = $answer.files
    # A text the receiver gets no token for was taken from its preview, already.
    $sent = @($Items | Where-Object { $null -ne $_.Text -and -not $tokens.PSObject.Properties[$_.Id] }).Count
    try {
        foreach ($i in $Items) {
            $tp = $tokens.PSObject.Properties[$i.Id]
            if (-not $tp) { continue }
            $q = 'sessionId=' + [Uri]::EscapeDataString($session) + '&fileId=' + [Uri]::EscapeDataString($i.Id) + '&token=' + [Uri]::EscapeDataString([string]$tp.Value)
            if ($i.Path) { $u = Invoke-VivacLocalSendHttp $Device 'POST' "$api/upload?$q" $null $i.Path -TimeoutMs 120000 -ContentType 'application/octet-stream' }
            else { $u = Invoke-VivacLocalSendHttp $Device 'POST' "$api/upload?$q" $utf8.GetBytes($i.Text) -TimeoutMs 120000 -ContentType 'application/octet-stream' }
            if ($u.Status -ne 200) { throw (T 'localsend.refused_other' @($Device.Alias, $u.Status)) }
            $sent++
        }
    } catch {
        try { [void](Invoke-VivacLocalSendHttp $Device 'POST' ("$api/cancel?sessionId=" + [Uri]::EscapeDataString($session)) $null -TimeoutMs 5000) } catch { }
        throw
    }
    $sent
}

# The device to send to: -Peer, else discovery and -To (the whole alias, case
# aside, else the only one it starts), else a choice on screen.
function Resolve-DropDevice {
    if ($Peer) {
        $d = Find-VivacLocalSendPeer $Peer
        if (-not $d) { throw (T 'localsend.unreachable' @($Peer, 'no LocalSend there')) }
        return $d
    }
    $devices = @(Find-VivacLocalSendDevices)
    if (-not $devices.Count) { throw (T 'localsend.none_found') }
    if ($To) {
        $exact = @($devices | Where-Object { $_.Alias -eq $To })
        if ($exact.Count) { return $exact[0] }
        $starts = @($devices | Where-Object { $_.Alias.StartsWith($To, [StringComparison]::OrdinalIgnoreCase) })
        if ($starts.Count -eq 1) { return $starts[0] }
        throw (T 'localsend.not_found' @($To, (($devices | ForEach-Object { $_.Alias }) -join ', ')))
    }
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    $i = Select-VivacItem (T 'localsend.send_to') ([string[]]@($devices | ForEach-Object { Format-VivacLocalSendDevice $_ })) (T 'localsend.choose_hint')
    if ($i -lt 0) { return $null }
    $devices[$i]
}

function Send-Drop([object[]]$Items) {
    $device = Resolve-DropDevice
    if (-not $device) { return }
    $n = Send-DropItems $device $Items $Pin
    T 'localsend.sent' @($n, $device.Alias)
}

# ------------------------------------------------------------------ verbs

function Set-DropOn([bool]$On) {
    if ($On) {
        [void](& $PSCommandPath -Register)
        T 'localsend.now_on' @(Get-VivacLocalSendPin)
    } else {
        [void](& $PSCommandPath -Unregister)
        T 'localsend.now_off'
    }
}

if ($Notify) {
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    try {
        $said = (& $PSCommandPath $Verb @Rest) -join ' '
        if ($said) { Show-DropCard (T 'localsend.title') $said }
    } catch {
        Show-DropCard (T 'localsend.title') $_.Exception.Message
    }
    return
}

switch ($Verb) {
    'send' {
        $items = @()
        foreach ($t in @($Text | Where-Object { $_ })) { $items += New-DropItem '' $t }
        foreach ($f in @($Rest | Where-Object { $_ })) {
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw (T 'localsend.no_file' @($f)) }
            if ((Get-Item -LiteralPath $f).Length -gt (Get-VivacLocalSendFileLimit)) { throw (T 'localsend.too_large' @($f)) }
            $items += New-DropItem (Resolve-Path -LiteralPath $f).ProviderPath ''
        }
        if (-not $items.Count) { throw 'usage: vivac-localsend.ps1 send FILE... [-Text TEXT] [-To ALIAS | -Peer HOST:PORT] [-Pin PIN]' }
        Send-Drop $items
    }
    'pick' {
        # Files from Windows' own picker (several with Ctrl or Shift), then
        # the phone.
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Multiselect = $true
        $dialog.Title = T 'localsend.pick'
        $dialog.InitialDirectory = Join-Path $paths.Profile 'Downloads'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
        $items = @($dialog.FileNames | ForEach-Object { New-DropItem $_ '' })
        Send-Drop $items
    }
    'devices' {
        $found = @(Find-VivacLocalSendDevices)
        if (-not $found.Count) { throw (T 'localsend.none_found') }
        foreach ($d in $found) { "$($d.Alias)`t$($d.Address):$($d.Port)`t$($d.Protocol)`t$($d.Model)" }
    }
    'status' {
        if (Test-DropOn) { T 'localsend.status_on' } else { T 'localsend.status_off' }
        $p = Get-VivacLocalSendPin
        if ($p) { T 'localsend.status_pin' @($p) } else { T 'localsend.status_no_pin' }
        T 'localsend.status_name' @((Get-VivacLocalSendAlias), (Get-VivacLocalSendPort))
        T 'localsend.status_inbox' @(Get-VivacLinkInbox)
    }
    'on' { Set-DropOn $true }
    'off' { Set-DropOn $false }
    'toggle' { Set-DropOn (-not (Test-DropOn)) }
    # The receiver reads the PIN at every request: nothing to restart.
    'pin' { New-VivacLocalSendPin -Again:$New }
    default { Get-Help $PSCommandPath -Detailed | Out-String | Write-Host }
}
