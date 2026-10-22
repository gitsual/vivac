# The phone drop: LocalSend's protocol (github.com/localsend/protocol, v2),
# so a phone with the stock LocalSend app sends files and texts here and gets
# them from here, with no vivac app on it. docs/bridge.md at the product root,
# "Phones: LocalSend". This module holds what the receiver and the sender
# share and what the gates check; bin/vivac-localsend.ps1 is the program.
#
#   this device      alias, fingerprint (a random string kept in the state,
#                    as LocalSend does over http), the PIN
#   checks           the PIN and its rate limit, prepare-upload's body
#   other devices    what they announce, what the receiver heard
#   talking          one HTTP request to a device, https only when its
#                    certificate's SHA-256 is the fingerprint it announced

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
# Received names and the inbox are vivac link's (Get-VivacSafeFileName, Get-VivacFreePath, Get-VivacLinkInbox).
Import-Module (Join-Path $PSScriptRoot 'Bridge.psm1')

$script:Utf8 = New-Object Text.UTF8Encoding $false
# LocalSend's port, for HTTP and discovery alike; the gates move it and keep
# discovery on the loopback (VIVAC_LOCALSEND_INTERFACES).
$script:Port = 53317
if ($env:VIVAC_LOCALSEND_PORT) { $script:Port = [int]$env:VIVAC_LOCALSEND_PORT }
$script:Group = '224.0.0.167'
$script:Api = '/api/localsend/v2'
$script:Version = '2.1'
$script:FileLimit = 2GB
$script:JsonLimit = 1MB
$script:PinTries = 5
$script:PinWindow = 60
$script:PinShape = '^[0-9A-Za-z]{4,32}$'

function Get-VivacLocalSendPort { $script:Port }
function Get-VivacLocalSendGroup { $script:Group }
function Get-VivacLocalSendApi { $script:Api }
function Get-VivacLocalSendFileLimit { $script:FileLimit }
function Get-VivacLocalSendJsonLimit { $script:JsonLimit }

# --------------------------------------------------------------- this device

function Get-VivacLocalSendAlias {
    if ($env:VIVAC_LOCALSEND_ALIAS) { return $env:VIVAC_LOCALSEND_ALIAS }
    $env:COMPUTERNAME
}

# Over http LocalSend's fingerprint is a random string: made once and kept,
# so phones remember this machine and it never answers its own announcement.
function Get-VivacLocalSendFingerprint {
    $path = Join-Path (Get-VivacPaths).State 'localsend-id'
    if (Test-Path -LiteralPath $path) {
        $text = ([IO.File]::ReadAllText($path)).Trim()
        if ($text -match '^[0-9a-f]{32}$') { return $text }
    }
    $text = -join @((New-VivacLocalSendBytes 16) | ForEach-Object { $_.ToString('x2') })
    Write-VivacFile -Path $path -Text "$text`n"
    $text
}

function New-VivacLocalSendBytes([int]$Count) {
    $bytes = New-Object byte[] $Count
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    , $bytes
}

function New-VivacLocalSendToken { -join @((New-VivacLocalSendBytes 16) | ForEach-Object { $_.ToString('x2') }) }

function Get-VivacLocalSendPinPath { Join-Path (Get-VivacPaths).State 'localsend.pin' }

# localsend_pin from the settings unless auto, else the stored one; empty
# while there is none.
function Get-VivacLocalSendPin {
    $chosen = [string](Read-VivacSettings)['localsend_pin']
    if ($chosen -ne 'auto' -and $chosen -match $script:PinShape) { return $chosen }
    $path = Get-VivacLocalSendPinPath
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $stored = ([IO.File]::ReadAllText($path)).Trim()
    if ($stored -match $script:PinShape) { return $stored }
    ''
}

# The PIN, made (six random digits) when there is none or when asked anew.
# Readable by this user only, like vivac link's pairing.
function New-VivacLocalSendPin([switch]$Again) {
    $chosen = [string](Read-VivacSettings)['localsend_pin']
    if ($chosen -ne 'auto' -and $chosen -match $script:PinShape) { return $chosen }
    $pin = ''
    if (-not $Again) { $pin = Get-VivacLocalSendPin }
    if ($pin) { return $pin }
    $pin = -join @((New-VivacLocalSendBytes 6) | ForEach-Object { [string]($_ % 10) })
    $path = Get-VivacLocalSendPinPath
    Write-VivacFile -Path $path -Text "$pin`n"
    & icacls.exe $path /inheritance:r /grant:r "$($env:USERNAME):(F)" 2>&1 | Out-Null
    $pin
}

# What this device says about itself: LocalSend's register and announce body.
function Get-VivacLocalSendInfo([int]$Port = $script:Port, $Announce = $null) {
    $info = [ordered]@{
        alias       = Get-VivacLocalSendAlias
        version     = $script:Version
        deviceModel = 'Windows'
        deviceType  = 'desktop'
        fingerprint = Get-VivacLocalSendFingerprint
        port        = $Port
        protocol    = 'http'
        download    = $false
    }
    if ($null -ne $Announce) { $info['announce'] = [bool]$Announce }
    $info
}

function ConvertTo-VivacLocalSendJson($Value) { $Value | ConvertTo-Json -Compress -Depth 6 }

# ------------------------------------------------------------------- checks

# Seconds on a clock that only goes forward (the wall clock may be set back).
function Get-VivacLocalSendClock { [Diagnostics.Stopwatch]::GetTimestamp() / [double][Diagnostics.Stopwatch]::Frequency }

# Whether a prepare-upload may go on: 0, or 401 without the PIN or with a
# wrong one, 429 once an address has had five wrong ones in the last minute
# (even if the sixth is right). $Failures is the receiver's memory:
# address -> list of times.
function Test-VivacLocalSendPin([hashtable]$Failures, [string]$Address, [string]$Given, [string]$Pin, [double]$Now = (Get-VivacLocalSendClock)) {
    $recent = New-Object Collections.ArrayList
    if ($Failures.ContainsKey($Address)) {
        foreach ($t in $Failures[$Address]) { if ($Now - $t -lt $script:PinWindow) { [void]$recent.Add($t) } }
    }
    $Failures[$Address] = $recent
    if ($recent.Count -ge $script:PinTries) { return 429 }
    if (-not $Given) { return 401 }
    if (-not $Pin -or -not (Test-VivacLocalSendSame $Given $Pin)) { [void]$recent.Add($Now); return 401 }
    0
}

# Equal strings, compared in a time that does not depend on where they differ.
function Test-VivacLocalSendSame([string]$A, [string]$B) {
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int]$A[$i] -bxor [int]$B[$i]) }
    $diff -eq 0
}

# A text, as LocalSend sends one: a .txt whose preview is the text itself.
function Test-VivacLocalSendMessage($Entry) {
    $preview = $Entry.PSObject.Properties['preview']
    $type = $Entry.PSObject.Properties['fileType']
    ($preview -and $preview.Value -is [string] -and $type -and ([string]$type.Value).StartsWith('text/'))
}

# prepare-upload's body read as data: the sender's alias, the texts, and the
# files with their safe names. Throws 'status N: reason' for what is refused.
function Read-VivacLocalSendPrepare([string]$Json) {
    try { $body = $Json | ConvertFrom-Json } catch { throw 'status 400: not JSON' }
    if (-not $body -or -not $body.PSObject.Properties['files'] -or -not $body.files -or -not @($body.files.PSObject.Properties).Count) { throw 'status 400: no files' }
    $alias = ''
    if ($body.PSObject.Properties['info'] -and $body.info -and $body.info.PSObject.Properties['alias']) {
        $alias = ([string]$body.info.alias -replace '[\x00-\x1f\x7f]', '')
        if ($alias.Length -gt 64) { $alias = $alias.Substring(0, 64) }
    }
    $files = [ordered]@{}
    $texts = New-Object Collections.ArrayList
    foreach ($p in $body.files.PSObject.Properties) {
        $e = $p.Value
        if ($null -eq $e -or -not $e.PSObject.Properties['fileName'] -or -not $e.PSObject.Properties['size']) { throw 'status 400: malformed file' }
        $size = 0L
        if (-not [long]::TryParse([string]$e.size, [ref]$size) -or $size -lt 0) { throw 'status 400: malformed file' }
        if ($size -gt $script:FileLimit) { throw 'status 413: larger than 2 GiB' }
        if (Test-VivacLocalSendMessage $e) { [void]$texts.Add([string]$e.preview); continue }
        $sha = ''
        if ($e.PSObject.Properties['sha256'] -and [string]$e.sha256 -match '^[0-9a-fA-F]{64}$') { $sha = ([string]$e.sha256).ToLowerInvariant() }
        $files[[string]$p.Name] = [pscustomobject]@{
            Name = Get-VivacSafeFileName ([string]$e.fileName); Size = $size; Sha256 = $sha
            Token = New-VivacLocalSendToken; Done = $false
        }
    }
    [pscustomobject]@{ Alias = $alias; Files = $files; Texts = @($texts) }
}

# A text for a card: no control characters but line breaks, not too long.
function Format-VivacLocalSendText([string]$Text) {
    $t = $Text -replace '[\x00-\x09\x0b-\x1f\x7f]', ''
    if ($t.Length -gt 2000) { $t = $t.Substring(0, 2000) + '...' }
    $t
}

# ------------------------------------------------------------ other devices

# A device from what it announced or registered with; $null for anything
# malformed.
function ConvertTo-VivacLocalSendDevice($Message, [string]$Address) {
    if ($null -eq $Message -or $Message -isnot [pscustomobject]) { return $null }
    $props = $Message.PSObject.Properties
    if (-not $props['alias'] -or -not $props['fingerprint'] -or -not [string]$Message.fingerprint) { return $null }
    $port = $script:Port
    if ($props['port']) { if (-not [int]::TryParse([string]$Message.port, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return $null } }
    $protocol = 'https'
    if ($props['protocol']) { $protocol = [string]$Message.protocol }
    if (@('http', 'https') -notcontains $protocol) { return $null }
    $alias = ([string]$Message.alias -replace '[\x00-\x1f\x7f]', '')
    if ($alias.Length -gt 64) { $alias = $alias.Substring(0, 64) }
    if (-not $alias) { $alias = '?' }
    $model = ''
    if ($props['deviceModel'] -and $Message.deviceModel) { $model = ([string]$Message.deviceModel -replace '[\x00-\x1f\x7f]', '') }
    $mark = [string]$Message.fingerprint
    if ($mark.Length -gt 128) { $mark = $mark.Substring(0, 128) }
    [pscustomobject]@{ Alias = $alias; Address = $Address; Port = $port; Protocol = $protocol; Fingerprint = $mark; Model = $model; Seen = (Get-VivacUnixSeconds) }
}

function Get-VivacUnixSeconds { [long][Math]::Floor(([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds) }

function Format-VivacLocalSendDevice($Device) {
    $model = ''
    if ($Device.Model) { $model = "$($Device.Model), " }
    "$($Device.Alias) ($model$($Device.Address))"
}

function Get-VivacLocalSendDevicesPath { Join-Path (Get-VivacPaths).State 'localsend-devices.json' }

# What the receiver hears goes into a small file the sender reads while the
# receiver holds the port; older than ten minutes is forgotten.
function Add-VivacLocalSendDevice($Device) {
    $known = @{}
    foreach ($d in @(Get-VivacLocalSendKnownDevices 600)) { $known[$d.Fingerprint] = $d }
    $known[$Device.Fingerprint] = $Device
    Write-VivacFile -Path (Get-VivacLocalSendDevicesPath) -Text (ConvertTo-Json -InputObject @($known.Values) -Compress)
}

function Get-VivacLocalSendKnownDevices([long]$NewerThan) {
    $path = Get-VivacLocalSendDevicesPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { $rows = @([IO.File]::ReadAllText($path, $script:Utf8) | ConvertFrom-Json) } catch { return @() }
    $now = Get-VivacUnixSeconds
    @($rows | Where-Object { $_ -and $_.PSObject.Properties['Seen'] -and ($now - [long]$_.Seen) -le $NewerThan })
}

# This machine's IPv4 addresses, to join the group and announce on each one.
function Get-VivacLocalSendInterfaces {
    if ($env:VIVAC_LOCALSEND_INTERFACES) { return @($env:VIVAC_LOCALSEND_INTERFACES -split ',') }
    @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
            ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
            Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() })
}

# A UDP socket in LocalSend's group, sharing the port with anyone else in it
# (the receiver and a sender on one machine both are). $null when it cannot.
function New-VivacLocalSendMulticast([int]$Port = $script:Port) {
    $udp = New-Object Net.Sockets.UdpClient
    try {
        $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Any, $Port)))
    } catch { $udp.Close(); return $null }
    $joined = $false
    foreach ($local in @(Get-VivacLocalSendInterfaces)) {
        try { $udp.JoinMulticastGroup([Net.IPAddress]::Parse($script:Group), [Net.IPAddress]::Parse($local)); $joined = $true } catch { }
    }
    if (-not $joined) {
        try { $udp.JoinMulticastGroup([Net.IPAddress]::Parse($script:Group)) } catch { $udp.Close(); return $null }
    }
    $udp
}

# One datagram to the group, from every interface that has an address.
function Send-VivacLocalSendShout($Message, [int]$Port = $script:Port) {
    $bytes = $script:Utf8.GetBytes((ConvertTo-VivacLocalSendJson $Message))
    $target = New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($script:Group), $Port)
    foreach ($local in @(Get-VivacLocalSendInterfaces)) {
        $udp = New-Object Net.Sockets.UdpClient
        try {
            $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastTimeToLive, 1)
            $udp.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastInterface, [Net.IPAddress]::Parse($local).GetAddressBytes())
            [void]$udp.Send($bytes, $bytes.Length, $target)
        } catch { } finally { $udp.Close() }
    }
}

# ------------------------------------------------------------------ talking

function Get-VivacLocalSendSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join @($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

function Get-VivacLocalSendFileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { -join @($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) } finally { $stream.Dispose(); $sha.Dispose() }
}

function ConvertTo-VivacLocalSendMark([string]$Text) { ($Text.ToLowerInvariant() -replace '[^0-9a-f]', '') }

# A stream to a device. Over https its certificate is self-signed, so no
# authority vouches for it: LocalSend's trust is that its SHA-256 is the
# fingerprint the device announced, checked here before anything is sent.
# With -Learn, an https device's fingerprint is taken from what it shows
# (a device given by address, which announced nothing).
function Open-VivacLocalSendStream($Device, [int]$TimeoutMs = 10000, [switch]$Learn) {
    $client = New-Object Net.Sockets.TcpClient
    $ar = $client.BeginConnect($Device.Address, [int]$Device.Port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne([Math]::Min($TimeoutMs, 5000)) -or -not $client.Connected) { $client.Close(); throw "unreachable: $($Device.Address):$($Device.Port)" }
    $client.EndConnect($ar)
    $client.ReceiveTimeout = $TimeoutMs; $client.SendTimeout = $TimeoutMs
    $stream = $client.GetStream()
    if ($Device.Protocol -eq 'https') {
        $accept = [Net.Security.RemoteCertificateValidationCallback] { $true }
        $ssl = New-Object Net.Security.SslStream ($stream, $false, $accept)
        $protocols = [Security.Authentication.SslProtocols]::Tls12
        if ([Enum]::GetNames([Security.Authentication.SslProtocols]) -contains 'Tls13') { $protocols = $protocols -bor [Security.Authentication.SslProtocols]'Tls13' }
        try { $ssl.AuthenticateAsClient([string]$Device.Address, $null, $protocols, $false) }
        catch { $client.Close(); throw "unreachable: TLS with $($Device.Address) failed" }
        $seen = Get-VivacLocalSendSha256 $ssl.RemoteCertificate.GetRawCertData()
        if ($Learn) { $Device.Fingerprint = $seen }
        elseif (-not (Test-VivacLocalSendSame $seen (ConvertTo-VivacLocalSendMark $Device.Fingerprint))) { $client.Close(); throw "untrusted: $(Format-VivacLocalSendDevice $Device)" }
        $stream = $ssl
    }
    [pscustomobject]@{ Client = $client; Stream = $stream }
}

# One request: the body is bytes or a file streamed from disk. Returns the
# status and the body of the answer (chunked or not).
function Invoke-VivacLocalSendHttp($Device, [string]$Method, [string]$Path, [byte[]]$Body, [string]$BodyFile = '', [int]$TimeoutMs = 10000, [switch]$Learn, [string]$ContentType = 'application/json') {
    $conn = Open-VivacLocalSendStream $Device $TimeoutMs -Learn:$Learn
    try {
        $s = $conn.Stream
        $length = 0L
        if ($BodyFile) { $length = (Get-Item -LiteralPath $BodyFile).Length } elseif ($Body) { $length = $Body.Length }
        $head = "$Method $Path HTTP/1.1`r`nHost: $($Device.Address):$($Device.Port)`r`nContent-Length: $length`r`n"
        if ($length) { $head += "Content-Type: $ContentType`r`n" }
        $head += "Connection: close`r`n`r`n"
        $hb = $script:Utf8.GetBytes($head)
        $s.Write($hb, 0, $hb.Length)
        if ($BodyFile) {
            $in = [IO.File]::OpenRead($BodyFile)
            try {
                $buffer = New-Object byte[] 1MB
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) { $s.Write($buffer, 0, $n) }
            } finally { $in.Dispose() }
        } elseif ($Body) { $s.Write($Body, 0, $Body.Length) }
        $s.Flush()
        Read-VivacLocalSendResponse $s
    } finally { $conn.Client.Close() }
}

function Read-VivacLocalSendLine([IO.Stream]$Stream) {
    $line = New-Object IO.MemoryStream
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }
        if ($b -eq 10) { break }
        if ($b -ne 13) { $line.WriteByte([byte]$b) }
        if ($line.Length -gt 16KB) { throw 'line too long' }
    }
    $script:Utf8.GetString($line.ToArray())
}

function Read-VivacLocalSendResponse([IO.Stream]$Stream) {
    $status = 0
    $first = Read-VivacLocalSendLine $Stream
    if ($first -match '^HTTP/1\.[01] (\d{3})') { $status = [int]$Matches[1] }
    $headers = @{}
    while ($true) {
        $l = Read-VivacLocalSendLine $Stream
        if (-not $l) { break }
        $i = $l.IndexOf(':')
        if ($i -gt 0) { $headers[$l.Substring(0, $i).Trim().ToLowerInvariant()] = $l.Substring($i + 1).Trim() }
    }
    $out = New-Object IO.MemoryStream
    $buffer = New-Object byte[] 65536
    if ([string]$headers['transfer-encoding'] -match 'chunked') {
        while ($true) {
            $size = [Convert]::ToInt32(((Read-VivacLocalSendLine $Stream) -split ';')[0].Trim(), 16)
            if ($size -le 0) { break }
            while ($size -gt 0) {
                $n = $Stream.Read($buffer, 0, [Math]::Min($size, $buffer.Length))
                if ($n -le 0) { break }
                $out.Write($buffer, 0, $n); $size -= $n
            }
            [void](Read-VivacLocalSendLine $Stream)
            if ($out.Length -gt $script:JsonLimit) { break }
        }
    } elseif ($headers.ContainsKey('content-length')) {
        $left = [long]$headers['content-length']
        while ($left -gt 0 -and $out.Length -le $script:JsonLimit) {
            $n = $Stream.Read($buffer, 0, [int][Math]::Min($left, $buffer.Length))
            if ($n -le 0) { break }
            $out.Write($buffer, 0, $n); $left -= $n
        }
    } else {
        while ($out.Length -le $script:JsonLimit) {
            try { $n = $Stream.Read($buffer, 0, $buffer.Length) } catch { break }
            if ($n -le 0) { break }
            $out.Write($buffer, 0, $n)
        }
    }
    [pscustomobject]@{ Status = $status; Body = $script:Utf8.GetString($out.ToArray()) }
}

# A device at a known address (-Peer), for when multicast does not get
# through: https first, as phones speak it, then http.
function Find-VivacLocalSendPeer([string]$Peer) {
    if ($Peer -notmatch '^(?:(https?)://)?(\[[^\]]+\]|[^:/]+)(?::(\d+))?/?$') { return $null }
    $scheme = $Matches[1]; $peerHost = $Matches[2].Trim('[', ']'); $port = $script:Port
    if ($Matches[3]) { $port = [int]$Matches[3] }
    $schemes = @('https', 'http')
    if ($scheme) { $schemes = @($scheme) }
    foreach ($protocol in $schemes) {
        $device = [pscustomobject]@{ Alias = $peerHost; Address = $peerHost; Port = $port; Protocol = $protocol; Fingerprint = ''; Model = ''; Seen = 0 }
        try { $r = Invoke-VivacLocalSendHttp $device 'GET' "$script:Api/info" $null -TimeoutMs 5000 -Learn } catch { continue }
        if ($r.Status -ne 200) { continue }
        try { $info = $r.Body | ConvertFrom-Json } catch { continue }
        $learned = $device.Fingerprint
        $info | Add-Member -NotePropertyName port -NotePropertyValue $port -Force
        $info | Add-Member -NotePropertyName protocol -NotePropertyValue $protocol -Force
        if ($learned) { $info | Add-Member -NotePropertyName fingerprint -NotePropertyValue $learned -Force }
        $found = ConvertTo-VivacLocalSendDevice $info $peerHost
        if ($found) { return $found }
    }
    $null
}

# Who answers LocalSend here: announce, then listen for $Seconds to UDP
# answers and to /register, on a short-lived listener of our own on the
# LocalSend port or, while the receiver holds it, through what the receiver
# writes down.
function Find-VivacLocalSendDevices([double]$Seconds = 2) {
    $own = Get-VivacLocalSendFingerprint
    $found = @{}
    $listener = $null
    try {
        $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Any, $script:Port)
        $listener.Start()
    } catch { $listener = $null }
    $udp = New-VivacLocalSendMulticast
    $started = Get-VivacUnixSeconds
    $deadline = (Get-Date).AddSeconds($Seconds)
    $shouts = 0
    try {
        while ((Get-Date) -lt $deadline) {
            if ($shouts -lt 3 -and (Get-Date) -ge $deadline.AddSeconds(- $Seconds * (3 - $shouts) / 3)) {
                Send-VivacLocalSendShout (Get-VivacLocalSendInfo -Announce $true)
                $shouts++
            }
            while ($udp -and $udp.Available -gt 0) {
                $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
                $bytes = $udp.Receive([ref]$ep)
                try { $d = ConvertTo-VivacLocalSendDevice ($script:Utf8.GetString($bytes) | ConvertFrom-Json) $ep.Address.ToString() } catch { $d = $null }
                if ($d -and $d.Fingerprint -ne $own) { $found[$d.Fingerprint] = $d }
            }
            while ($listener -and $listener.Pending()) {
                $d = Receive-VivacLocalSendRegister $listener.AcceptTcpClient()
                if ($d -and $d.Fingerprint -ne $own) { $found[$d.Fingerprint] = $d }
            }
            Start-Sleep -Milliseconds 50
        }
    } finally {
        if ($udp) { $udp.Close() }
        if ($listener) { $listener.Stop() }
    }
    if (-not $listener) {
        foreach ($d in @(Get-VivacLocalSendKnownDevices ((Get-VivacUnixSeconds) - $started + 1))) {
            if ($d.Fingerprint -ne $own) { $found[$d.Fingerprint] = $d }
        }
    }
    @($found.Values | Sort-Object { $_.Alias.ToLowerInvariant() })
}

# One /register on the short-lived listener: the device it describes, and
# this device's info as the answer.
function Receive-VivacLocalSendRegister([Net.Sockets.TcpClient]$Client) {
    try {
        $Client.ReceiveTimeout = 3000; $Client.SendTimeout = 3000
        $s = $Client.GetStream()
        $first = Read-VivacLocalSendLine $s
        $length = 0
        while ($true) {
            $l = Read-VivacLocalSendLine $s
            if (-not $l) { break }
            if ($l -match '^(?i)content-length:\s*(\d{1,7})$') { $length = [int]$Matches[1] }
        }
        $body = New-Object byte[] ([Math]::Min($length, $script:JsonLimit))
        $got = 0
        while ($got -lt $body.Length) { $n = $s.Read($body, $got, $body.Length - $got); if ($n -le 0) { break }; $got += $n }
        $answer = $script:Utf8.GetBytes((ConvertTo-VivacLocalSendJson (Get-VivacLocalSendInfo)))
        $head = $script:Utf8.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($answer.Length)`r`nConnection: close`r`n`r`n")
        $s.Write($head, 0, $head.Length); $s.Write($answer, 0, $answer.Length)
        if ($first -notmatch "^POST $([regex]::Escape($script:Api))/register ") { return $null }
        ConvertTo-VivacLocalSendDevice ($script:Utf8.GetString($body, 0, $got) | ConvertFrom-Json) $Client.Client.RemoteEndPoint.Address.ToString()
    } catch { $null } finally { $Client.Close() }
}

Export-ModuleMember -Function *
