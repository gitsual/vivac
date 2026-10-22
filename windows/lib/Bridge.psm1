# The bridge: what this half does together with the Linux half. The contract
# both implement is docs/bridge.md at the root of the product; this module is
# the Windows side of it, without any window or network listener (those are
# bin/vivac-link.ps1 and bin/vivac-reboot-other.ps1).
#
#   shared root      the folder of the shared settings file, on a disk both
#                    systems mount; the drop tray lives under it
#   link             the signed requests two paired machines send each other

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')

$script:Utf8 = New-Object Text.UTF8Encoding $false

# ------------------------------------------------------- shared root, drop tray

# The folder that holds the shared settings file, or $null while there is none
# (shared_settings=none): nothing that needs the shared disk runs then.
function Get-VivacSharedRoot {
    $path = Get-VivacSharedPath
    if (-not $path) { return $null }
    Split-Path -Parent $path
}

# The drop tray: 'in' is what Linux left for this side, 'out' is where this
# side leaves things for Linux. $null without a shared root.
function Get-VivacDropFolder([ValidateSet('in', 'out')][string]$Direction, [string]$Root = (Get-VivacSharedRoot)) {
    if (-not $Root) { return $null }
    $leaf = if ($Direction -eq 'in') { 'to-windows' } else { 'to-linux' }
    Join-Path (Join-Path $Root 'drop') $leaf
}

# What is waiting in the tray: files and folders, not the dot files and
# desktop.ini a file manager leaves behind.
function Get-VivacDropItems([string]$Folder) {
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return @() }
    @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ne 'desktop.ini' -and $_.Name -ne 'Thumbs.db' })
}

# --------------------------------------------------------------------- link

$script:LinkPort = 47321
$script:LinkProtocol = 2
$script:LinkVerbs = @('clip', 'url', 'file', 'notify', 'ping', 'mouse')
$script:Base32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
# A file's name rides inside its sealed body, before a NUL.
$script:LinkNameLimit = 1024
# What sealing adds to a body: the IV, a block of padding at most, a file's name and its NUL.
$script:LinkSealRoom = 16 + 16 + 1024 + 1

function Get-VivacLinkDefaultPort { $script:LinkPort }
function Get-VivacLinkProtocol { $script:LinkProtocol }
function Get-VivacLinkVerbs { $script:LinkVerbs }
function Get-VivacLinkNameLimit { $script:LinkNameLimit }

# RFC 4648 base32, no padding: what the pairing code is written in.
function ConvertTo-VivacBase32([byte[]]$Bytes) {
    $sb = New-Object Text.StringBuilder
    $buffer = 0; $bits = 0
    foreach ($b in $Bytes) {
        $buffer = (($buffer -shl 8) -bor $b) -band 0xFFFF; $bits += 8
        while ($bits -ge 5) { $bits -= 5; [void]$sb.Append($script:Base32[($buffer -shr $bits) -band 31]) }
    }
    if ($bits -gt 0) { [void]$sb.Append($script:Base32[($buffer -shl (5 - $bits)) -band 31]) }
    $sb.ToString()
}

function ConvertFrom-VivacBase32([string]$Text) {
    $clean = ($Text.ToUpperInvariant() -replace '[\s=-]', '')
    $out = New-Object Collections.Generic.List[byte]
    $buffer = 0; $bits = 0
    foreach ($c in $clean.ToCharArray()) {
        $v = $script:Base32.IndexOf($c)
        if ($v -lt 0) { throw "vivac link: '$c' is not part of a pairing code" }
        $buffer = (($buffer -shl 5) -bor $v) -band 0xFFFF; $bits += 5
        if ($bits -ge 8) { $bits -= 8; $out.Add([byte](($buffer -shr $bits) -band 255)) }
    }
    , $out.ToArray()
}

# A new secret: 32 random bytes.
function New-VivacLinkSecret {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    , $bytes
}

# The code a person types on the other machine: base32 in groups of five.
function Format-VivacLinkCode([byte[]]$Secret) {
    $b32 = ConvertTo-VivacBase32 $Secret
    (($b32 -split '(.{5})' | Where-Object { $_ }) -join '-')
}

function ConvertFrom-VivacLinkCode([string]$Code) {
    $bytes = ConvertFrom-VivacBase32 $Code
    if ($bytes.Length -ne 32) { throw 'vivac link: a pairing code holds 32 bytes; this one does not' }
    , $bytes
}

function ConvertTo-VivacHex([byte[]]$Bytes) {
    -join @($Bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-VivacSha256Hex([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ConvertTo-VivacHex $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
}

function Get-VivacHmac([byte[]]$Key, [string]$Text) {
    $h = New-Object Security.Cryptography.HMACSHA256 (, $Key)
    try { , $h.ComputeHash($script:Utf8.GetBytes($Text)) } finally { $h.Dispose() }
}

function Get-VivacHmacHex([byte[]]$Key, [string]$Text) { ConvertTo-VivacHex (Get-VivacHmac $Key $Text) }

# One key per use from the shared secret: never the same key to encrypt and
# to sign (docs/bridge.md, "Requests").
function Get-VivacLinkKeys([byte[]]$Secret) {
    [pscustomobject]@{
        Seal = Get-VivacHmac $Secret "vivac-link v$($script:LinkProtocol) encrypt"
        Sign = Get-VivacHmac $Secret "vivac-link v$($script:LinkProtocol) sign"
    }
}

function New-VivacAes([byte[]]$Key) {
    $aes = New-Object Security.Cryptography.AesCryptoServiceProvider
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $Key
    $aes
}

# AES-256-CBC under a fresh IV, PKCS#7 padded: the IV, then the ciphertext.
# What is sealed is signed after (encrypt-then-MAC), and checked before it is
# opened.
function Protect-VivacLinkBody([byte[]]$Key, [byte[]]$Plain) {
    if ($null -eq $Plain) { $Plain = New-Object byte[] 0 }
    $aes = New-VivacAes $Key
    try {
        $aes.GenerateIV()
        $enc = $aes.CreateEncryptor()
        $cipher = $enc.TransformFinalBlock($Plain, 0, $Plain.Length)
        $out = New-Object byte[] (16 + $cipher.Length)
        [Array]::Copy($aes.IV, 0, $out, 0, 16)
        [Array]::Copy($cipher, 0, $out, 16, $cipher.Length)
        , $out
    } finally { $aes.Dispose() }
}

# The plain bytes back; throws when $Sealed is not a sealed body.
function Unprotect-VivacLinkBody([byte[]]$Key, [byte[]]$Sealed) {
    if ($null -eq $Sealed -or $Sealed.Length -lt 32 -or $Sealed.Length % 16) { throw 'vivac link: not a sealed body' }
    $aes = New-VivacAes $Key
    try {
        $iv = New-Object byte[] 16
        [Array]::Copy($Sealed, 0, $iv, 0, 16)
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        , $dec.TransformFinalBlock($Sealed, 16, $Sealed.Length - 16)
    } finally { $aes.Dispose() }
}

# What every request is signed with: the protocol, the verb, the time, the
# nonce and the sealed body's hash, one per line (docs/bridge.md, "Requests").
function Get-VivacLinkSignature([byte[]]$Key, [string]$Verb, [string]$Time, [string]$Nonce, [byte[]]$Body) {
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    Get-VivacHmacHex $Key ("v$($script:LinkProtocol)`n$Verb`n$Time`n$Nonce`n" + (Get-VivacSha256Hex $Body))
}

# An answer is signed over its request's nonce: it cannot be passed off for
# the answer to another.
function Get-VivacLinkAnswerSignature([byte[]]$Key, [string]$Nonce, [byte[]]$Body) {
    Get-VivacHmacHex $Key ("v$($script:LinkProtocol) answer`n$Nonce`n" + (Get-VivacSha256Hex $Body))
}

# Wake-on-LAN: six 0xFF, then the hardware address sixteen times.
function Get-VivacMagicPacket([string]$Mac) {
    if ($Mac -notmatch '^([0-9a-f]{2}:){5}[0-9a-f]{2}$') { throw "vivac link: '$Mac' is not a hardware address" }
    $address = [byte[]]@($Mac -split ':' | ForEach-Object { [Convert]::ToByte($_, 16) })
    $packet = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
    for ($i = 0; $i -lt 16; $i++) { [Array]::Copy($address, 0, $packet, 6 + 6 * $i, 6) }
    , $packet
}

# The hardware address of the interface holding $Address, for the peer to wake
# this machine with; '' when there is none (loopback, a tunnel).
function Get-VivacMacOf([string]$Address) {
    foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        $ips = @($nic.GetIPProperties().UnicastAddresses | ForEach-Object { $_.Address.ToString() })
        if ($ips -notcontains $Address) { continue }
        $bytes = $nic.GetPhysicalAddress().GetAddressBytes()
        if ($bytes.Length -ne 6 -or -not ($bytes | Where-Object { $_ })) { return '' }
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join ':')
    }
    ''
}

# What a beacon carries so two paired machines find each other without
# saying the secret.
function Get-VivacLinkId([byte[]]$Secret) { (Get-VivacHmacHex $Secret 'vivac-link-id').Substring(0, 16) }

function New-VivacLinkNonce {
    $bytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    ConvertTo-VivacHex $bytes
}

function Get-VivacUnixTime { [long][Math]::Floor(([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds) }

# The most a verb's body may weigh, before sealing; on the wire, sealing adds
# up to Get-VivacLinkSealRoom.
function Get-VivacLinkLimit([string]$Verb) {
    if ($Verb -eq 'file') { return 64MB }
    64KB
}
function Get-VivacLinkSealRoom { $script:LinkSealRoom }

# Equal strings, compared in a time that does not depend on where they differ.
function Test-VivacSameText([string]$A, [string]$B) {
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int]$A[$i] -bxor [int]$B[$i]) }
    $diff -eq 0
}

# Why a request is refused, or $null when it is good. $Seen is the receiver's
# memory of nonces (nonce -> unix time); a good request is added to it, and
# entries older than two minutes are forgotten.
function Test-VivacLinkRequest([byte[]]$Key, [string]$Verb, [string]$Time, [string]$Nonce, [string]$Sign, [byte[]]$Body, [hashtable]$Seen, [long]$Now = (Get-VivacUnixTime)) {
    $t = 0L
    if (-not [long]::TryParse($Time, [ref]$t)) { return 'no time' }
    if ([Math]::Abs($Now - $t) -gt 60) { return 'time too far from ours' }
    if ($Nonce -notmatch '^[0-9a-f]{32}$') { return 'no nonce' }
    foreach ($k in @($Seen.Keys)) { if ($Now - $Seen[$k] -gt 120) { $Seen.Remove($k) } }
    if ($Seen.ContainsKey($Nonce)) { return 'nonce already seen' }
    if (-not (Test-VivacSameText (Get-VivacLinkSignature $Key $Verb $Time $Nonce $Body) "$Sign".ToLowerInvariant())) { return 'bad signature' }
    $Seen[$Nonce] = $Now
    $null
}

# One request to a vivac link listener, headers as given (the client seals
# and signs; the gates also send what no client would). Returns the status,
# the headers (lower-case names), the body's bytes and the body as text.
function Invoke-VivacLinkHttp([string]$PeerHost, [int]$Port, [string]$Verb, [byte[]]$Body, [Collections.IDictionary]$Headers, [int]$ConnectMs = 5000, [string]$Path = '') {
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    if (-not $Path) { $Path = "/v$($script:LinkProtocol)/$Verb" }
    $head = "POST $Path HTTP/1.1`r`nHost: $PeerHost`r`nContent-Length: $($Body.Length)`r`n"
    foreach ($k in $Headers.Keys) { $head += "${k}: $($Headers[$k])`r`n" }
    $head += "Connection: close`r`n`r`n"
    $client = New-Object Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($PeerHost, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ConnectMs) -or -not $client.Connected) { throw "vivac link: could not reach ${PeerHost}:$Port" }
        $client.EndConnect($ar)
        $client.ReceiveTimeout = 60000; $client.SendTimeout = 60000
        $stream = $client.GetStream()
        $hb = $script:Utf8.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        # A listener that refuses on the headers alone closes before taking a
        # large body; its answer is still read.
        try { $stream.Write($Body, 0, $Body.Length) } catch { }
        $received = New-Object IO.MemoryStream
        $stream.CopyTo($received)
        $raw = $received.ToArray()
    } finally { $client.Close() }
    # The head is text up to the first blank line; the body is bytes (sealed).
    $split = -1
    for ($i = 0; $i -le $raw.Length - 4; $i++) {
        if ($raw[$i] -eq 13 -and $raw[$i + 1] -eq 10 -and $raw[$i + 2] -eq 13 -and $raw[$i + 3] -eq 10) { $split = $i; break }
    }
    $headText = if ($split -ge 0) { [Text.Encoding]::ASCII.GetString($raw, 0, $split) } else { [Text.Encoding]::ASCII.GetString($raw) }
    $bytes = New-Object byte[] 0
    if ($split -ge 0) {
        $bytes = New-Object byte[] ($raw.Length - $split - 4)
        [Array]::Copy($raw, $split + 4, $bytes, 0, $bytes.Length)
    }
    $status = 0
    if ($headText -match '^HTTP/1\.[01] (\d{3})') { $status = [int]$Matches[1] }
    $answerHeaders = @{}
    foreach ($l in @($headText -split "`r`n" | Select-Object -Skip 1)) {
        $c = $l.IndexOf(':')
        if ($c -gt 0) { $answerHeaders[$l.Substring(0, $c).Trim().ToLowerInvariant()] = $l.Substring($c + 1).Trim() }
    }
    [pscustomobject]@{ Status = $status; Headers = $answerHeaders; Bytes = $bytes; Body = $script:Utf8.GetString($bytes) }
}

# ---------------------------------------------------------------- link state

function Get-VivacLinkConfPath { Join-Path (Get-VivacPaths).State 'link.conf' }
function Get-VivacLinkPeerPath { Join-Path (Get-VivacPaths).State 'link-peer' }
function Get-VivacLinkPeerMacPath { Join-Path (Get-VivacPaths).State 'link-peer-mac' }

# The pairing: secret (bytes), name, port and peer. $null when not paired.
function Read-VivacLinkConf {
    $kv = Read-VivacKeyValue (Get-VivacLinkConfPath)
    if (-not $kv.Exists -or -not $kv.Values['secret']) { return $null }
    $port = 0
    if (-not [int]::TryParse([string]$kv.Values['port'], [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $port = $script:LinkPort }
    $name = [string]$kv.Values['name']
    if (-not $name) { $name = $env:COMPUTERNAME }
    [pscustomobject]@{
        Secret = ConvertFrom-VivacLinkCode $kv.Values['secret']
        Name   = $name
        Port   = $port
        Peer   = [string]$kv.Values['peer']
    }
}

# Writes the pairing, readable by this user only: the secret is a password.
function Write-VivacLinkConf([byte[]]$Secret, [string]$Name = $env:COMPUTERNAME, [int]$Port = $script:LinkPort, [string]$Peer = '') {
    $path = Get-VivacLinkConfPath
    $text = "# vivac link pairing (docs/bridge.md). The secret is a password: keep it here.`nsecret=$(ConvertTo-VivacBase32 $Secret)`nname=$Name`nport=$Port`n"
    if ($Peer) { $text += "peer=$Peer`n" }
    Write-VivacFile -Path $path -Text $text
    & icacls.exe $path /inheritance:r /grant:r "$($env:USERNAME):(F)" 2>&1 | Out-Null
}

# Where to reach the peer: the address in link.conf, else the one discovery
# last saw.
function Get-VivacLinkPeer($Conf) {
    if ($Conf -and $Conf.Peer) { return $Conf.Peer }
    $p = Get-VivacLinkPeerPath
    if (Test-Path -LiteralPath $p) { return ([IO.File]::ReadAllText($p)).Trim() }
    $null
}

# ---------------------------------------------------------------- link files

# A file's name as received, made safe to write: no folder, no characters
# Windows refuses, no device names, never empty.
function Get-VivacSafeFileName([string]$Name) {
    $leaf = ($Name -split '[\\/]')[-1]
    $bad = [IO.Path]::GetInvalidFileNameChars()
    $leaf = -join @($leaf.ToCharArray() | ForEach-Object { if ($bad -contains $_ -or [int]$_ -lt 32) { '_' } else { $_ } })
    $leaf = $leaf.Trim().TrimEnd('.', ' ')
    if ($leaf -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $leaf = "_$leaf" }
    if (-not $leaf -or $leaf -match '^\.+$') { $leaf = 'file' }
    if ($leaf.Length -gt 200) { $leaf = $leaf.Substring(0, 200) }
    $leaf
}

# A path in $Folder for $Name that does not exist yet: name, name (2), ...
function Get-VivacFreePath([string]$Folder, [string]$Name) {
    $path = Join-Path $Folder $Name
    if (-not (Test-Path -LiteralPath $path)) { return $path }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name); $ext = [IO.Path]::GetExtension($Name)
    for ($i = 2; ; $i++) {
        $path = Join-Path $Folder "$base ($i)$ext"
        if (-not (Test-Path -LiteralPath $path)) { return $path }
    }
}

# Where received files go: Downloads\vivac-link (VIVAC_LINK_INBOX in the gates).
function Get-VivacLinkInbox {
    if ($env:VIVAC_LINK_INBOX) { return $env:VIVAC_LINK_INBOX }
    $downloads = $null
    try { $downloads = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch { }
    if (-not $downloads) { $downloads = Join-Path (Get-VivacPaths).Profile 'Downloads' }
    Join-Path $downloads 'vivac-link'
}

Export-ModuleMember -Function *
