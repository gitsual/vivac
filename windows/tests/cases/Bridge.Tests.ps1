# The bridge (lib/Bridge.psm1, bin/vivac-link.ps1, docs/bridge.md at the
# product root): the pairing code, the signature both halves compute, and
# vivac link end to end on the loopback, in a scratch profile, with nothing
# reaching the screen (VIVAC_LINK_SINK).
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\Bridge.psm1') -Force
$utf8 = New-Object Text.UTF8Encoding $false

Case 'base32 is RFC 4648 and a pairing code round-trips' {
    Assert-Equal 'MZXW6YTBOI' (ConvertTo-VivacBase32 ([Text.Encoding]::ASCII.GetBytes('foobar')))
    $s = New-VivacLinkSecret
    $code = Format-VivacLinkCode $s
    Assert-True ($code -match '^([A-Z2-7]{5}-)+[A-Z2-7]{1,5}$') "code shape: $code"
    Assert-Equal ([Convert]::ToBase64String($s)) ([Convert]::ToBase64String((ConvertFrom-VivacLinkCode $code.ToLowerInvariant())))
    Assert-Throws { ConvertFrom-VivacLinkCode 'ABCDE' } '32 bytes'
}
# The Linux half computes these with Python's hmac and hashlib; the values
# here were taken from it, so a change on either side shows.
Case 'the signature and the beacon id match the Linux half' {
    $k = [Text.Encoding]::ASCII.GetBytes('k' * 32)
    Assert-Equal '997cceaea71dee209de633e2dd96a8f3d923d176763ba12ced867c9af5b310d1' (Get-VivacLinkSignature $k 'clip' '1700000000' ('0' * 32) $utf8.GetBytes('hola'))
    Assert-Equal '074c73367dfa6047' (Get-VivacLinkId $k)
}
Case 'a request is refused when stale, replayed or badly signed' {
    $k = [Text.Encoding]::ASCII.GetBytes('k' * 32)
    $seen = @{}
    $body = [byte[]](1, 2, 3)
    $sig = Get-VivacLinkSignature $k 'file' '1700000000' ('a' * 32) $body
    Assert-Equal $null (Test-VivacLinkRequest $k 'file' '1700000000' ('a' * 32) $sig $body $seen 1700000030)
    Assert-True (Test-VivacLinkRequest $k 'file' '1700000000' ('a' * 32) $sig $body $seen 1700000031) 'replay'
    Assert-True (Test-VivacLinkRequest $k 'file' '1700000000' ('b' * 32) $sig $body $seen 1700000061) 'stale'
    Assert-True (Test-VivacLinkRequest $k 'clip' '1700000000' ('c' * 32) $sig $body $seen 1700000001) 'signed for another verb'
}
Case 'a received file name is made safe' {
    Assert-Equal '_con.txt' (Get-VivacSafeFileName '..\..\Windows\con.txt')
    Assert-Equal 'passwd' (Get-VivacSafeFileName '/etc/passwd')
    Assert-Equal 'b_c_.txt' (Get-VivacSafeFileName 'a/b:c?.txt')
    Assert-Equal 'file' (Get-VivacSafeFileName '..')
}

# ------------------------------------------------------------ end to end

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('vivac-link-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$env:VIVAC_LOCALAPPDATA = Join-Path $scratch 'local'
$env:VIVAC_APPDATA = Join-Path $scratch 'roaming'
$env:VIVAC_LINK_SINK = Join-Path $scratch 'sink'
$env:VIVAC_LINK_INBOX = Join-Path $scratch 'inbox'
foreach ($d in $env:VIVAC_LOCALAPPDATA, $env:VIVAC_APPDATA, $env:VIVAC_LINK_SINK) { [void](New-Item -ItemType Directory -Force -Path $d) }
$port = Get-Random -Minimum 40000 -Maximum 60000
$secret = New-VivacLinkSecret
Write-VivacLinkConf $secret 'gate' $port "127.0.0.1:$port"
$link = Join-Path $root 'bin\vivac-link.ps1'
$listener = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$link`"", '-Serve')

function Invoke-Link([string[]]$LinkArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $link @LinkArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
# A request as given, for what the client never sends.
function Send-Unsigned([string]$Verb, [byte[]]$Body, [string]$Time, [string]$Nonce, [string]$Sign) {
    (Invoke-VivacLinkHttp '127.0.0.1' $port $Verb $Body @{ 'X-Vivac-Time' = $Time; 'X-Vivac-Nonce' = $Nonce; 'X-Vivac-Sign' = $Sign }).Status
}

try {
    # The listener is up when it answers.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try { [void](Invoke-VivacLinkHttp '127.0.0.1' $port 'ping' $null @{} 500); break } catch { Start-Sleep -Milliseconds 250 }
    }

    Case 'link: ping answers with the name and the system' {
        $r = Invoke-Link @('ping')
        Assert-Equal 0 $r.Code $r.Text
        $j = $r.Text | ConvertFrom-Json
        Assert-Equal 'gate' $j.name
        Assert-Equal 'windows' $j.os
        Assert-Equal 1 $j.protocol
    }
    Case 'link: a file lands in the inbox under a safe name, never overwriting' {
        $src = Join-Path $scratch 'hello world.txt'
        [IO.File]::WriteAllText($src, 'hola')
        Assert-Equal 0 (Invoke-Link @('send-file', $src)).Code
        Assert-Equal 0 (Invoke-Link @('send-file', $src)).Code
        Assert-Equal 'hola' ([IO.File]::ReadAllText((Join-Path $env:VIVAC_LINK_INBOX 'hello world.txt')))
        Assert-True (Test-Path -LiteralPath (Join-Path $env:VIVAC_LINK_INBOX 'hello world (2).txt')) 'second copy beside the first'
    }
    Case 'link: a link and a notification become cards; a link is never opened' {
        Assert-Equal 0 (Invoke-Link @('send-url', 'https://example.org/a?b=c')).Code
        Assert-Equal 0 (Invoke-Link @('notify', 'Title', 'the', 'body')).Code
        $cards = [IO.File]::ReadAllText((Join-Path $env:VIVAC_LINK_SINK 'cards.txt'))
        Assert-True ($cards -match '\|https://example\.org/a\?b=c\|') 'the link is offered on click'
        Assert-True ($cards -match 'Title\|the body') 'the notification'
        Assert-True ((Invoke-Link @('send-url', 'file:///C:/Windows')).Code -ne 0) 'a file: link is refused before it is sent'
    }
    Case 'link: clip reaches the clipboard (the sink here)' {
        $body = $utf8.GetBytes('portapapeles ' + [char]0xF1)
        $t = [string](Get-VivacUnixTime); $n = New-VivacLinkNonce
        Assert-Equal 200 (Send-Unsigned 'clip' $body $t $n (Get-VivacLinkSignature $secret 'clip' $t $n $body))
        Assert-Equal ('portapapeles ' + [char]0xF1) ([IO.File]::ReadAllText((Join-Path $env:VIVAC_LINK_SINK 'clip.txt'), $utf8))
    }
    Case 'link: 401 for a bad signature, a replay or a stale time; 413 too big; 404 unknown' {
        $body = $utf8.GetBytes('x')
        $t = [string](Get-VivacUnixTime); $n = New-VivacLinkNonce
        Assert-Equal 401 (Send-Unsigned 'clip' $body $t $n ('0' * 64))
        $sig = Get-VivacLinkSignature $secret 'clip' $t $n $body
        Assert-Equal 200 (Send-Unsigned 'clip' $body $t $n $sig)
        Assert-Equal 401 (Send-Unsigned 'clip' $body $t $n $sig)
        $old = [string]((Get-VivacUnixTime) - 300); $n2 = New-VivacLinkNonce
        Assert-Equal 401 (Send-Unsigned 'clip' $body $old $n2 (Get-VivacLinkSignature $secret 'clip' $old $n2 $body))
        Assert-Equal 413 (Send-Unsigned 'clip' (New-Object byte[] (64KB + 1)) $t (New-VivacLinkNonce) 'x')
        Assert-Equal 404 (Send-Unsigned 'shell' $body $t (New-VivacLinkNonce) 'x')
    }
} finally {
    if ($listener -and -not $listener.HasExited) { Stop-Process -Id $listener.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Cases
