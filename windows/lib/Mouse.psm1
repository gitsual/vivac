# The shared mouse: one keyboard and mouse for two machines, through lan-mouse
# (docs/bridge.md at the product root, "One keyboard and mouse"). lan-mouse
# does the work; this module only keeps vivac's mouse.conf, writes
# lan-mouse's config.toml from it and reads this machine's certificate
# fingerprint. No window, no network, no task: bin/vivac-mouse.ps1 has those.
#
# config.toml is written byte for byte as the Linux half writes it, so one
# expected file checks both.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')

$script:Utf8 = New-Object Text.UTF8Encoding $false
$script:MousePort = 4242
$script:Sides = @('left', 'right', 'top', 'bottom')
$script:Opposite = @{ left = 'right'; right = 'left'; top = 'bottom'; bottom = 'top' }

function Get-VivacMouseConfPath { Join-Path (Get-VivacPaths).State 'mouse.conf' }

# Where lan-mouse keeps config.toml and its certificate: %LOCALAPPDATA%\lan-mouse.
function Get-VivacLanMouseDir { Join-Path (Get-VivacPaths).LocalAppData 'lan-mouse' }

# lan-mouse.exe: VIVAC_LAN_MOUSE when set (the gates point it at a fake, or
# at nothing), else the PATH, else the link winget makes for a portable
# package (packages/mouse.txt). $null when it is not installed.
function Find-VivacLanMouse {
    if ($env:VIVAC_LAN_MOUSE) {
        if (Test-Path -LiteralPath $env:VIVAC_LAN_MOUSE -PathType Leaf) { return $env:VIVAC_LAN_MOUSE }
        return $null
    }
    $cmd = Get-Command 'lan-mouse' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\lan-mouse.exe'
    if (Test-Path -LiteralPath $link) { return $link }
    $null
}

function Get-VivacMouseSides { $script:Sides }
function Get-VivacMouseOpposite([string]$Side) { $script:Opposite[$Side] }

# ------------------------------------------------------- what is checked first

# A SHA-256 fingerprint as lan-mouse writes it (32 lowercase hex pairs joined
# by colons), from any case, with or without the colons. $null otherwise.
function ConvertTo-VivacFingerprint([string]$Text) {
    $digits = ($Text -replace '[\s:]', '').ToLowerInvariant()
    if ($digits -notmatch '^[0-9a-f]{64}$') { return $null }
    (0..31 | ForEach-Object { $digits.Substring($_ * 2, 2) }) -join ':'
}

# A host name or an IP address, nothing that could break out of a TOML
# string. IPv4 only as four dotted numbers: .NET would take "7" for 0.0.0.7.
function ConvertTo-VivacMousePeer([string]$Text) {
    $t = $Text.Trim()
    $ip = $null
    if ((Test-VivacMouseIp $t) -and [Net.IPAddress]::TryParse($t, [ref]$ip)) { return $ip.ToString() }
    if ($t.Length -le 253 -and $t -cmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}(\.[A-Za-z0-9][A-Za-z0-9-]{0,62})*$') { return $t }
    $null
}

# Four dotted numbers, or hex with colons: what Python's ipaddress takes too.
function Test-VivacMouseIp([string]$Peer) {
    $ip = $null
    ($Peer -match '^\d{1,3}(\.\d{1,3}){3}$' -or ($Peer -match '^[0-9A-Fa-f:]+$' -and $Peer.Contains(':'))) -and [Net.IPAddress]::TryParse($Peer, [ref]$ip)
}

function ConvertTo-VivacMousePort([string]$Text) {
    $n = 0
    if ($Text -match '^\d{1,5}$' -and [int]::TryParse($Text, [ref]$n) -and $n -ge 1 -and $n -le 65535) { return $n }
    $null
}

# -------------------------------------------------------------- certificate

# What lan-mouse shows as this machine's fingerprint: SHA-256 of the DER
# bytes of the first CERTIFICATE block of lan-mouse.pem (the private key block
# beside it is skipped), lowercase hex pairs joined by colons.
function Get-VivacPemFingerprint([string]$Text) {
    foreach ($m in [regex]::Matches($Text, '-----BEGIN ([A-Z0-9_ ]+)-----\s*(.*?)\s*-----END \1-----', 'Singleline')) {
        if ($m.Groups[1].Value -cne 'CERTIFICATE') { continue }
        try { $der = [Convert]::FromBase64String(($m.Groups[2].Value -replace '\s', '')) } catch { return $null }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($der) } finally { $sha.Dispose() }
        return ConvertTo-VivacFingerprint (-join @($hash | ForEach-Object { $_.ToString('x2') }))
    }
    $null
}

function Get-VivacOwnFingerprint {
    $pem = Join-Path (Get-VivacLanMouseDir) 'lan-mouse.pem'
    if (-not (Test-Path -LiteralPath $pem)) { return $null }
    try { Get-VivacPemFingerprint ([IO.File]::ReadAllText($pem)) } catch { $null }
}

# ------------------------------------------------- mouse.conf and config.toml

# enabled, peer, side, fingerprint, port: each kept only when it is valid.
function Read-VivacMouseConf {
    $s = [ordered]@{ enabled = 'no'; port = [string]$script:MousePort }
    $values = @{}
    try { $values = (Read-VivacKeyValue (Get-VivacMouseConfPath)).Values } catch { }
    if ($values['enabled'] -eq 'yes') { $s.enabled = 'yes' }
    if ($values['peer']) { $p = ConvertTo-VivacMousePeer $values['peer']; if ($p) { $s.peer = $p } }
    if ($script:Sides -contains [string]$values['side']) { $s.side = [string]$values['side'] }
    if ($values['fingerprint']) { $f = ConvertTo-VivacFingerprint $values['fingerprint']; if ($f) { $s.fingerprint = $f } }
    if ($values['port']) { $n = ConvertTo-VivacMousePort $values['port']; if ($n) { $s.port = [string]$n } }
    $s
}

function Get-VivacMouseConfText($Settings) {
    $text = "# vivac mouse (docs/bridge.md): what vivac-mouse writes lan-mouse's config.toml from.`n"
    foreach ($k in 'enabled', 'peer', 'side', 'fingerprint', 'port') {
        if ($Settings.Contains($k)) { $text += "$k=$($Settings[$k])`n" }
    }
    $text
}

# lan-mouse's config.toml, all of it. Every value was checked on the way in,
# so each goes between quotes as it is. Top-level keys first, as TOML wants.
function Get-VivacLanMouseToml($Settings) {
    $port = $Settings['port']
    $t = "# lan-mouse, as vivac-mouse writes it from ~/.local/state/vivac/mouse.conf.`n" +
        "# vivac-mouse config and vivac-mouse trust change it; edits here are replaced.`n" +
        "`nport = $port`n"
    if ($Settings.Contains('fingerprint')) {
        $label = 'vivac peer'
        if ($Settings.Contains('peer')) { $label = $Settings['peer'] }
        $t += "`n# the only certificate accepted for incoming input`n[authorized_fingerprints]`n`"$($Settings['fingerprint'])`" = `"$label`"`n"
    }
    if ($Settings.Contains('peer') -and $Settings.Contains('side')) {
        $where = "hostname = `"$($Settings['peer'])`""
        if (Test-VivacMouseIp $Settings['peer']) { $where = "ips = [`"$($Settings['peer'])`"]" }
        $t += "`n# the other machine, and the edge of this screen it sits beyond`n[[clients]]`n" +
            "position = `"$($Settings['side'])`"`n$where`nport = $port`nactivate_on_startup = true`n"
    }
    $t
}

# mouse.conf, then config.toml from it. A config.toml vivac did not write
# (the default lan-mouse makes on its first start, or one written by hand) is
# kept once beside it as config.toml.vivac-backup.
function Save-VivacMouse($Settings) {
    Write-VivacFile -Path (Get-VivacMouseConfPath) -Text (Get-VivacMouseConfText $Settings)
    $toml = Join-Path (Get-VivacLanMouseDir) 'config.toml'
    $backup = "$toml.vivac-backup"
    if ((Test-Path -LiteralPath $toml) -and -not (Test-Path -LiteralPath $backup)) {
        if ([IO.File]::ReadAllText($toml) -notmatch 'vivac-mouse') { Copy-Item -LiteralPath $toml -Destination $backup }
    }
    Write-VivacFile -Path $toml -Text (Get-VivacLanMouseToml $Settings)
}

Export-ModuleMember -Function *
