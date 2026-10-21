# The shared mouse (lib/Mouse.psm1, bin/vivac-mouse.ps1, docs/bridge.md at
# the product root): lan-mouse's config.toml written byte for byte as the
# Linux half writes it, only from values that were checked; this machine's
# fingerprint read out of lan-mouse.pem as lan-mouse computes it; and the
# verbs in a scratch profile, with a fake lan-mouse.exe and no task ever
# registered (enable and disable only as dry runs).
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Mouse.psm1') -Force
$utf8 = New-Object Text.UTF8Encoding $false

# Fingerprints are built here from plain hex: written out with their colons
# they would look like MAC addresses to the privacy gate.
function ConvertTo-Colons([string]$Hex) { (0..31 | ForEach-Object { $Hex.Substring($_ * 2, 2) }) -join ':' }
# The DER bytes are a sentence; the Linux half (test_bridge_mouse.sh) checks
# the same file against the same SHA-256.
$certHex = '15f4f310adea63bc5bf152d7a5e95456dddd33a106cb4283336e6176f0c8f03e'
$pem = "-----BEGIN PRIVATE_KEY-----`nbm90IGEga2V5`n-----END PRIVATE_KEY-----`n`n-----BEGIN CERTIFICATE-----`ndml2YWMgbW91c2U6IGEgdGVz`ndCBjZXJ0aWZpY2F0ZSwgbm90IERFUg==`n-----END CERTIFICATE-----`n"
$peerHex = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff'

Case 'the fingerprint is SHA-256 of the certificate, the key block skipped' {
    Assert-Equal (ConvertTo-Colons $certHex) (Get-VivacPemFingerprint $pem)
    Assert-Equal (ConvertTo-Colons $certHex) (Get-VivacPemFingerprint ($pem -replace "`n", "`r`n"))
    Assert-Equal $null (Get-VivacPemFingerprint "-----BEGIN PRIVATE_KEY-----`nbm90IGEga2V5`n-----END PRIVATE_KEY-----`n")
}
Case 'a fingerprint is 32 hex pairs, in any case, with or without colons' {
    Assert-Equal (ConvertTo-Colons $peerHex) (ConvertTo-VivacFingerprint $peerHex.ToUpperInvariant())
    Assert-Equal (ConvertTo-Colons $peerHex) (ConvertTo-VivacFingerprint (ConvertTo-Colons $peerHex))
    Assert-Equal $null (ConvertTo-VivacFingerprint 'aa:bb')
    Assert-Equal $null (ConvertTo-VivacFingerprint ('g' * 64))
}
Case 'a peer is a host name or an IP address, nothing that breaks a TOML string' {
    Assert-Equal 'other-pc' (ConvertTo-VivacMousePeer ' other-pc ')
    Assert-Equal '198.51.100.7' (ConvertTo-VivacMousePeer '198.51.100.7')
    Assert-Equal '7' (ConvertTo-VivacMousePeer '7')
    Assert-True (-not (Test-VivacMouseIp '7')) 'a bare number is a host name, as on Linux'
    foreach ($bad in 'a"b', 'x]y', 'a b', '-lead', '') { Assert-Equal $null (ConvertTo-VivacMousePeer $bad) "accepted: $bad" }
    Assert-Equal $null (ConvertTo-VivacMousePort '70000')
    Assert-Equal 4300 (ConvertTo-VivacMousePort '4300')
}
Case 'config.toml is exactly what the Linux half writes' {
    $expected = "# lan-mouse, as vivac-mouse writes it from ~/.local/state/vivac/mouse.conf.`n" +
        "# vivac-mouse config and vivac-mouse trust change it; edits here are replaced.`n`nport = 4242`n`n" +
        "# the only certificate accepted for incoming input`n[authorized_fingerprints]`n`"$(ConvertTo-Colons $peerHex)`" = `"other-pc`"`n`n" +
        "# the other machine, and the edge of this screen it sits beyond`n[[clients]]`nposition = `"right`"`nhostname = `"other-pc`"`nport = 4242`nactivate_on_startup = true`n"
    $s = [ordered]@{ enabled = 'no'; port = '4242'; peer = 'other-pc'; side = 'right'; fingerprint = (ConvertTo-Colons $peerHex) }
    Assert-True ((Get-VivacLanMouseToml $s) -ceq $expected) "got:`n$(Get-VivacLanMouseToml $s)"
    $s.peer = '198.51.100.7'
    Assert-True ((Get-VivacLanMouseToml $s) -match "(?m)^ips = \[`"198\.51\.100\.7`"\]$") 'an IP goes in ips'
}

# ------------------------------------------------------------ the verbs

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('vivac-mouse-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$env:VIVAC_LOCALAPPDATA = Join-Path $scratch 'local'
$env:VIVAC_APPDATA = Join-Path $scratch 'roaming'
$fake = Join-Path $scratch 'lan-mouse.exe'
foreach ($d in $env:VIVAC_LOCALAPPDATA, $env:VIVAC_APPDATA) { [void](New-Item -ItemType Directory -Force -Path $d) }
[IO.File]::WriteAllText($fake, 'not a program')
$env:VIVAC_LAN_MOUSE = $fake
$tool = Join-Path $root 'bin\vivac-mouse.ps1'
$toml = Join-Path $env:VIVAC_LOCALAPPDATA 'lan-mouse\config.toml'
$conf = Join-Path $env:VIVAC_LOCALAPPDATA 'vivac\mouse.conf'

function Invoke-Mouse([string[]]$MouseArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool @MouseArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

try {
    Case 'mouse: no certificate, no fingerprint; then the one in lan-mouse.pem' {
        Assert-Equal 1 (Invoke-Mouse @('fingerprint')).Code
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $toml))
        [IO.File]::WriteAllText((Join-Path (Split-Path $toml) 'lan-mouse.pem'), $pem, $utf8)
        $r = Invoke-Mouse @('fingerprint')
        Assert-Equal 0 $r.Code $r.Text
        Assert-Equal (ConvertTo-Colons $certHex) $r.Text.Trim()
    }
    Case 'mouse: config -DryRun shows the file and writes nothing' {
        $r = Invoke-Mouse @('config', '-Peer', 'other-pc', '-Side', 'right', '-Fingerprint', $peerHex, '-DryRun')
        Assert-Equal 0 $r.Code $r.Text
        Assert-True ($r.Text -match '\[\[clients\]\]') $r.Text
        Assert-True (-not (Test-Path -LiteralPath $toml)) 'config.toml written by a dry run'
        Assert-True (-not (Test-Path -LiteralPath $conf)) 'mouse.conf written by a dry run'
    }
    Case 'mouse: config writes both files and keeps a foreign config.toml once' {
        [IO.File]::WriteAllText($toml, "# what lan-mouse writes on its first start`nport = 4242`n")
        $r = Invoke-Mouse @('config', '-Peer', 'other-pc', '-Side', 'top', '-Fingerprint', $peerHex.ToUpperInvariant())
        Assert-Equal 0 $r.Code $r.Text
        $text = [IO.File]::ReadAllText($toml)
        Assert-True ($text -match '(?m)^position = "top"$') $text
        Assert-True ($text.Contains((ConvertTo-Colons $peerHex))) 'the fingerprint, in lan-mouse''s form'
        Assert-True ([IO.File]::ReadAllText("$toml.vivac-backup") -match 'first start') 'the foreign file was kept'
        Assert-True ([IO.File]::ReadAllText($conf) -match '(?m)^enabled=no$') 'config turned the mouse on'
    }
    Case 'mouse: refused values leave config.toml as it was' {
        $before = [IO.File]::ReadAllText($toml)
        Assert-Equal 2 (Invoke-Mouse @('config', '-Peer', 'a"b', '-Side', 'left')).Code
        Assert-Equal 2 (Invoke-Mouse @('config', '-Peer', 'other-pc', '-Side', 'middle')).Code
        Assert-Equal 2 (Invoke-Mouse @('config', '-Peer', 'other-pc', '-Side', 'left', '-Fingerprint', 'aa:bb')).Code
        Assert-Equal 2 (Invoke-Mouse @('trust', 'not-hex')).Code
        Assert-Equal $before ([IO.File]::ReadAllText($toml))
    }
    Case 'mouse: trust replaces the fingerprint; pair gives the opposite side' {
        $other = 'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100'
        Assert-Equal 0 (Invoke-Mouse @('trust', (ConvertTo-Colons $other))).Code
        Assert-True ([IO.File]::ReadAllText($toml).Contains("`"$(ConvertTo-Colons $other)`" = ")) 'trusted'
        $r = Invoke-Mouse @('pair')
        Assert-Equal 0 $r.Code $r.Text
        Assert-True ($r.Text.Contains("--side bottom --fingerprint $(ConvertTo-Colons $certHex)")) $r.Text
        Assert-True ($r.Text.Contains("-Side bottom -Fingerprint $(ConvertTo-Colons $certHex)")) $r.Text
    }
    Case 'mouse: enable and disable as dry runs name the task and change nothing' {
        $r = Invoke-Mouse @('enable', '-DryRun')
        Assert-Equal 0 $r.Code $r.Text
        Assert-True ($r.Text -match 'Register-ScheduledTask \\vivac\\mouse \(AtLogOn\): conhost\.exe --headless ".*lan-mouse\.exe" daemon') $r.Text
        Assert-True ([IO.File]::ReadAllText($conf) -match '(?m)^enabled=no$') 'a dry run turned it on'
        $r = Invoke-Mouse @('disable', '-DryRun')
        Assert-Equal 0 $r.Code $r.Text
        Assert-True ($r.Text -match 'Unregister-ScheduledTask \\vivac\\mouse') $r.Text
        $env:VIVAC_LAN_MOUSE = Join-Path $scratch 'none.exe'
        Assert-Equal 1 (Invoke-Mouse @('enable', '-DryRun')).Code
        $env:VIVAC_LAN_MOUSE = $fake
    }
    Case 'mouse: apply-system -Mouse opens UDP 4242 to the local subnet only' {
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\apply-system.ps1') -Mouse -DryRun 2>&1) -join "`n"
        Assert-True ($out -match 'UDP 4242') $out
        Assert-True ($out -match 'vivac mouse') $out
        Assert-True ($out -notmatch 'TCP') $out
    }
    Case 'mouse: the menu offers it with lan-mouse, as it is now' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $rows = @(Get-VivacMenuEntries | Where-Object { $_.Target -eq 'mouse-toggle' })
        Assert-Equal 1 $rows.Count
        Assert-Equal (T 'bridge.mouse_off') $rows[0].Name
        $env:VIVAC_LAN_MOUSE = Join-Path $scratch 'none.exe'
        Assert-Equal 0 @(Get-VivacMenuEntries | Where-Object { $_.Target -eq 'mouse-toggle' }).Count
        $env:VIVAC_LAN_MOUSE = $fake
    }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Cases
