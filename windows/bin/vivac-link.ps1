<#
.SYNOPSIS
  vivac link: this machine and a paired one, Linux or Windows, on the same
  local network.

.DESCRIPTION
  The Windows side of docs/bridge.md, "vivac link". Every request is signed
  with the secret the two machines share; this side never runs what it
  receives, never opens a link unasked and writes received files only into
  Downloads\vivac-link.

    pair              make a new pairing and print its code
    pair CODE         take the pairing code made on the other machine
    status            whether this machine is paired, and with whom
    ping              ask the other machine who it is
    send-clip         send this clipboard's text
    send-url URL      send a link (the other side offers it, never opens it)
    send-file PATH    send a file (up to 64 MiB)
    notify TITLE BODY show a notification there

    -Serve       listen and announce (what the sign-in task runs)
    -Register    run -Serve at every sign-in, as \vivac\link, and start it
    -Unregister  remove that task and stop the listener

  Other machines reach it only through the firewall rule
  `apply-system.ps1 -Link` adds: private networks, local subnet, port 47321.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Verb,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest,
    [switch]$Serve,
    [switch]$Register,
    [switch]$Unregister,
    # Say how a send went in a notification, not on a console (the menu's
    # "send clipboard" runs without one).
    [switch]$Notify,
    # A notification the listener asked for, shown by a process of its own so
    # the listener never waits on a window.
    [string]$Card
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Bridge.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

$paths = Get-VivacPaths
$log = Join-Path $paths.State 'link.log'
$cards = Join-Path $paths.State 'link-cards'
$taskPath = '\vivac\'
$taskName = 'link'
$utf8 = New-Object Text.UTF8Encoding $false

function Write-LinkLog([string]$Line) {
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
    if ($c.open) { $target = [string]$c.open; $click = { Start-Process $target }.GetNewClosure() }
    if ($c.select) { $target = [string]$c.select; $click = { Start-Process explorer.exe -ArgumentList "/select,`"$target`"" }.GetNewClosure() }
    Show-VivacToast ([string]$c.title) ([string]$c.body) 'vivac link' '' '' $click
    # Until the card is gone: clicked, closed, or timed out.
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $t.Add_Tick({ if (-not (& (Get-Module Toasts) { $script:Stack.Count })) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } })
    $t.Start()
    [Windows.Threading.Dispatcher]::Run()
    return
}

# The gates run the listener with VIVAC_LINK_SINK set to a folder: what would
# reach the screen and the clipboard is written there instead.
$sink = $env:VIVAC_LINK_SINK

function Show-LinkCard([string]$Title, [string]$Body, [string]$Open = '', [string]$Select = '') {
    if ($sink) { Add-Content -LiteralPath (Join-Path $sink 'cards.txt') -Value "$Title|$Body|$Open|$Select" -Encoding UTF8; return }
    [void](New-Item -ItemType Directory -Force -Path $cards)
    $file = Join-Path $cards ([guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($file, (@{ title = $Title; body = $Body; open = $Open; select = $Select } | ConvertTo-Json -Compress), $utf8)
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Card', "`"$file`"")
}

# ------------------------------------------------------------------- task

if ($Unregister) {
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'vivac-link\.ps1' -and $_.CommandLine -match '-Serve' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    "removed $taskPath$taskName"
    return
}

if ($Register) {
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

# The peer as discovery last saw it: address and name.
function Read-DiscoveredPeer {
    $p = Get-VivacLinkPeerPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { [IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json } catch { $null }
}

function Get-PeerName {
    $d = Read-DiscoveredPeer
    if ($d -and $d.name) { return [string]$d.name }
    T 'link.other_machine'
}

# One request off the stream: request line, headers, body. Bounded: 16 KiB of
# headers, the verb's limit of body, ten seconds of silence.
function Read-LinkRequest([Net.Sockets.NetworkStream]$Stream) {
    $head = New-Object IO.MemoryStream
    $last4 = 0
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { return $null }
        $head.WriteByte([byte]$b)
        $last4 = (($last4 -shl 8) -bor $b) -band 0xFFFFFFFF
        if ($last4 -eq 0x0D0A0D0A) { break }
        if ($head.Length -gt 16KB) { return @{ Status = 431 } }
    }
    $lines = $utf8.GetString($head.ToArray()) -split "`r`n"
    if ($lines[0] -notmatch '^POST /v(\d+)/([a-z]+) HTTP/1\.[01]$') { return @{ Status = 404 } }
    $protocol = [int]$Matches[1]; $verb = $Matches[2]
    $headers = @{}
    foreach ($l in $lines[1..($lines.Count - 1)]) {
        $i = $l.IndexOf(':')
        if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() }
    }
    if ($protocol -ne 1 -or (Get-VivacLinkVerbs) -notcontains $verb) { return @{ Status = 404 } }
    $length = 0L
    if (-not [long]::TryParse([string]$headers['content-length'], [ref]$length) -or $length -lt 0) { return @{ Status = 411 } }
    if ($length -gt (Get-VivacLinkLimit $verb)) { return @{ Status = 413 } }
    $body = New-Object byte[] $length
    $got = 0
    while ($got -lt $length) {
        $n = $Stream.Read($body, $got, [int][Math]::Min(65536, $length - $got))
        if ($n -le 0) { return $null }
        $got += $n
    }
    @{ Status = 0; Verb = $verb; Headers = $headers; Body = $body }
}

function Write-LinkResponse([Net.Sockets.NetworkStream]$Stream, [int]$Status, [string]$Json) {
    $reason = @{ 200 = 'OK'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 404 = 'Not Found'; 411 = 'Length Required'; 413 = 'Payload Too Large'; 431 = 'Request Header Fields Too Large'; 500 = 'Internal Server Error' }[$Status]
    $bytes = $utf8.GetBytes($Json)
    $head = $utf8.GetBytes("HTTP/1.1 $Status $reason`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
    $Stream.Write($head, 0, $head.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
}

# What each verb does here. Returns the JSON answer.
function Invoke-LinkVerb([string]$Verb, [hashtable]$Headers, [byte[]]$Body, $Conf) {
    $from = Get-PeerName
    switch ($Verb) {
        'ping' {
            $version = ''
            $vf = Join-Path $root 'VERSION'
            if (Test-Path -LiteralPath $vf) { $version = ([IO.File]::ReadAllText($vf)).Trim() }
            return (@{ ok = $true; name = $Conf.Name; os = 'windows'; version = $version; protocol = 1 } | ConvertTo-Json -Compress)
        }
        'clip' {
            $text = $utf8.GetString($Body)
            if ($sink) { [IO.File]::WriteAllText((Join-Path $sink 'clip.txt'), $text, $utf8) } else { Set-Clipboard -Value $text }
            Show-LinkCard (T 'link.title') (T 'link.got_clip' @($from))
        }
        'url' {
            $url = $utf8.GetString($Body).Trim()
            $u = $null
            if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$u) -or @('http', 'https') -notcontains $u.Scheme) { return '{"ok":false,"error":"not an http or https link"}' }
            Show-LinkCard (T 'link.title') (T 'link.got_url' @($from, $u.Host)) $u.AbsoluteUri
        }
        'notify' {
            $n = $utf8.GetString($Body) | ConvertFrom-Json
            $title = [string]$n.title; $text = [string]$n.body
            if ($title.Length -gt 200) { $title = $title.Substring(0, 200) }
            if ($text.Length -gt 1000) { $text = $text.Substring(0, 1000) }
            Show-LinkCard "$from - $title" $text
        }
        'file' {
            $name = Get-VivacSafeFileName ([Uri]::UnescapeDataString([string]$Headers['x-vivac-name']))
            $inbox = Get-VivacLinkInbox
            [void](New-Item -ItemType Directory -Force -Path $inbox)
            $dest = Get-VivacFreePath $inbox $name
            [IO.File]::WriteAllBytes($dest, $Body)
            Show-LinkCard (T 'link.title') (T 'link.got_file' @($from, (Split-Path -Leaf $dest))) '' $dest
        }
    }
    '{"ok":true}'
}

function Invoke-LinkConnection([Net.Sockets.TcpClient]$Client, [hashtable]$Seen) {
    $Client.ReceiveTimeout = 10000; $Client.SendTimeout = 10000
    $stream = $Client.GetStream()
    $remote = $Client.Client.RemoteEndPoint
    try {
        $req = Read-LinkRequest $stream
        if (-not $req) { return }
        if ($req.Status) { Write-LinkResponse $stream $req.Status '{"ok":false}'; Write-LinkLog "refused $($req.Status) from $remote"; return }
        $conf = Read-VivacLinkConf
        if (-not $conf) { Write-LinkResponse $stream 401 '{"ok":false,"error":"not paired"}'; return }
        $h = $req.Headers
        $why = Test-VivacLinkRequest $conf.Secret $req.Verb ([string]$h['x-vivac-time']) ([string]$h['x-vivac-nonce']) ([string]$h['x-vivac-sign']) $req.Body $Seen
        if ($why) { Write-LinkResponse $stream 401 '{"ok":false}'; Write-LinkLog "refused 401 $($req.Verb) from ${remote}: $why"; return }
        $answer = Invoke-LinkVerb $req.Verb $h $req.Body $conf
        Write-LinkResponse $stream 200 $answer
        Write-LinkLog "$($req.Verb) from $remote ($($req.Body.Length) bytes)"
    } catch {
        Write-LinkLog "error with ${remote}: $($_.Exception.Message)"
        try { Write-LinkResponse $stream 500 '{"ok":false}' } catch { }
    } finally {
        # A request refused on its headers still has its body on the way:
        # closing on it would reset the connection and lose the answer. The
        # answer is sent, the rest read and dropped, a megabyte and a second
        # at most.
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

# This machine's own IPv4 addresses, so its own beacon is not taken for the
# peer's.
function Get-OwnAddresses {
    @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() })
}

function Send-LinkBeacon([Net.Sockets.UdpClient]$Udp, $Conf) {
    $beacon = @{ v = 1; name = $Conf.Name; os = 'windows'; port = $Conf.Port; id = (Get-VivacLinkId $Conf.Secret) } | ConvertTo-Json -Compress
    $bytes = $utf8.GetBytes($beacon)
    try { [void]$Udp.Send($bytes, $bytes.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Broadcast, $Conf.Port))) } catch { }
}

function Receive-LinkBeacons([Net.Sockets.UdpClient]$Udp, $Conf, [string[]]$Own) {
    while ($Udp.Available -gt 0) {
        $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
        $bytes = $Udp.Receive([ref]$ep)
        $sender = $ep.Address.ToString()
        if ($Own -contains $sender) { continue }
        try { $b = $utf8.GetString($bytes) | ConvertFrom-Json } catch { continue }
        if ($b.v -ne 1 -or [string]$b.id -ne (Get-VivacLinkId $Conf.Secret)) { continue }
        $port = 0
        if (-not [int]::TryParse([string]$b.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { continue }
        $peer = @{ address = "${sender}:$port"; name = [string]$b.name; os = [string]$b.os } | ConvertTo-Json -Compress
        $file = Get-VivacLinkPeerPath
        $old = ''
        if (Test-Path -LiteralPath $file) { $old = [IO.File]::ReadAllText($file, $utf8) }
        if ($old -ne $peer) { Write-VivacFile -Path $file -Text $peer; Write-LinkLog "peer $($b.name) at ${sender}:$port" }
    }
}

if ($Serve) {
    $conf = Read-VivacLinkConf
    $port = if ($conf) { $conf.Port } else { Get-VivacLinkDefaultPort }
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Any, $port)
    $listener.Start()
    $udp = New-Object Net.Sockets.UdpClient
    $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $udp.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Any, $port)))
    $udp.EnableBroadcast = $true
    Write-LinkLog "listening on $port (pid $PID)"
    $seen = @{}
    $lastBeacon = [datetime]::MinValue
    $own = Get-OwnAddresses
    while ($true) {
        try {
            if ($listener.Pending()) { Invoke-LinkConnection $listener.AcceptTcpClient() $seen }
            # Pairing can be made or changed while this runs: read it again.
            $conf = Read-VivacLinkConf
            if ($conf) {
                Receive-LinkBeacons $udp $conf $own
                if ((Get-Date) - $lastBeacon -ge [TimeSpan]::FromSeconds(30)) {
                    Send-LinkBeacon $udp $conf
                    $lastBeacon = Get-Date
                    $own = Get-OwnAddresses
                }
            } elseif ($udp.Available -gt 0) {
                $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0); [void]$udp.Receive([ref]$ep)
            }
        } catch {
            Write-LinkLog "loop: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 100
    }
}

# ------------------------------------------------------------------ client

function Send-LinkRequest([string]$Verb, [byte[]]$Body, [string]$FileName = '') {
    $conf = Read-VivacLinkConf
    if (-not $conf) { throw (T 'link.not_paired') }
    $peer = Get-VivacLinkPeer $conf
    if ($peer -and $peer.StartsWith('{')) { $peer = [string]($peer | ConvertFrom-Json).address }
    if (-not $peer) { throw (T 'link.no_peer') }
    $peerHost = $peer; $port = $conf.Port
    if ($peer -match '^(.+):(\d+)$') { $peerHost = $Matches[1]; $port = [int]$Matches[2] }
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    $time = [string](Get-VivacUnixTime)
    $nonce = New-VivacLinkNonce
    $headers = [ordered]@{ 'X-Vivac-Time' = $time; 'X-Vivac-Nonce' = $nonce; 'X-Vivac-Sign' = (Get-VivacLinkSignature $conf.Secret $Verb $time $nonce $Body) }
    if ($FileName) { $headers['X-Vivac-Name'] = [Uri]::EscapeDataString($FileName) }
    try { Invoke-VivacLinkHttp $peerHost $port $Verb $Body $headers }
    catch { throw (T 'link.unreachable' @($peer)) }
}
function Assert-LinkOk($Response) {
    if ($Response.Status -ne 200) { throw (T 'link.refused' @($Response.Status)) }
    $Response
}

if ($Notify) {
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    try {
        $said = (& $PSCommandPath $Verb @Rest) -join ' '
        Show-Notification (T 'link.title') $said
    } catch {
        Show-Notification (T 'link.title') $_.Exception.Message
    }
    return
}

switch ($Verb) {
    'pair' {
        if ($Rest -and $Rest[0]) {
            $secret = ConvertFrom-VivacLinkCode ($Rest -join '')
            Write-VivacLinkConf $secret
            T 'link.paired'
        } else {
            $secret = New-VivacLinkSecret
            Write-VivacLinkConf $secret
            T 'link.pair_code'
            ''
            '    ' + (Format-VivacLinkCode $secret)
            ''
            T 'link.pair_other'
        }
    }
    'status' {
        $conf = Read-VivacLinkConf
        if (-not $conf) { T 'link.not_paired'; return }
        T 'link.status_paired' @($conf.Name, $conf.Port)
        $peer = Get-VivacLinkPeer $conf
        if ($peer -and $peer.StartsWith('{')) { $d = $peer | ConvertFrom-Json; T 'link.status_peer' @($d.name, $d.address) }
        elseif ($peer) { T 'link.status_peer' @('', $peer) }
        else { T 'link.no_peer' }
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) { T 'link.status_task' @($task.State) } else { T 'link.status_no_task' }
    }
    'ping' { (Assert-LinkOk (Send-LinkRequest 'ping' $null)).Body }
    'send-clip' {
        $text = Get-Clipboard -Raw
        if (-not $text) { throw (T 'link.empty_clip') }
        [void](Assert-LinkOk (Send-LinkRequest 'clip' $utf8.GetBytes($text)))
        T 'link.sent'
    }
    'send-url' {
        $url = [string]($Rest -join ' ')
        $u = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$u) -or @('http', 'https') -notcontains $u.Scheme) { throw (T 'link.bad_url') }
        [void](Assert-LinkOk (Send-LinkRequest 'url' $utf8.GetBytes($u.AbsoluteUri)))
        T 'link.sent'
    }
    'send-file' {
        $path = (Resolve-Path -LiteralPath ($Rest -join ' ')).ProviderPath
        if ((Get-Item -LiteralPath $path).Length -gt (Get-VivacLinkLimit 'file')) { throw (T 'link.too_big') }
        [void](Assert-LinkOk (Send-LinkRequest 'file' ([IO.File]::ReadAllBytes($path)) (Split-Path -Leaf $path)))
        T 'link.sent'
    }
    'notify' {
        if (-not $Rest -or $Rest.Count -lt 1) { throw 'usage: vivac-link.ps1 notify TITLE [BODY]' }
        $body = ''
        if ($Rest.Count -gt 1) { $body = ($Rest[1..($Rest.Count - 1)] -join ' ') }
        $json = @{ title = $Rest[0]; body = $body } | ConvertTo-Json -Compress
        [void](Assert-LinkOk (Send-LinkRequest 'notify' $utf8.GetBytes($json)))
        T 'link.sent'
    }
    default { Get-Help $PSCommandPath -Detailed | Out-String | Write-Host }
}
