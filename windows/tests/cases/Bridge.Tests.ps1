# The bridge (lib/Bridge.psm1, bin/vivac-link.ps1, docs/bridge.md at the
# product root): the pairing code, the keys, the sealing and the signature
# both halves compute, and vivac link end to end on the loopback, in a
# scratch profile, with nothing reaching the screen (VIVAC_LINK_SINK).
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\Bridge.psm1') -Force
$utf8 = New-Object Text.UTF8Encoding $false

function ConvertFrom-Hex([string]$Hex) { , [byte[]]@(for ($i = 0; $i -lt $Hex.Length; $i += 2) { [Convert]::ToByte($Hex.Substring($i, 2), 16) }) }

Case 'base32 is RFC 4648 and a pairing code round-trips' {
    Assert-Equal 'MZXW6YTBOI' (ConvertTo-VivacBase32 ([Text.Encoding]::ASCII.GetBytes('foobar')))
    $s = New-VivacLinkSecret
    $code = Format-VivacLinkCode $s
    Assert-True ($code -match '^([A-Z2-7]{5}-)+[A-Z2-7]{1,5}$') "code shape: $code"
    Assert-Equal ([Convert]::ToBase64String($s)) ([Convert]::ToBase64String((ConvertFrom-VivacLinkCode $code.ToLowerInvariant())))
    Assert-Throws { ConvertFrom-VivacLinkCode 'ABCDE' } '32 bytes'
}
# The Linux half computes these with Python's hmac, hashlib and cryptography;
# the values here were taken from it, so a change on either side shows.
Case 'the keys, the signatures and the beacon id match the Linux half' {
    $k = [Text.Encoding]::ASCII.GetBytes('k' * 32)
    $keys = Get-VivacLinkKeys $k
    Assert-Equal '24faceb20df131a89c84817331b4eafa7abf013d8f78d95a79cc277c473cd4ec' (ConvertTo-VivacHex $keys.Seal)
    Assert-Equal 'ced6f28d56580f86819250058f8d22028ea3d5f800d6a6797e6b211cf347d207' (ConvertTo-VivacHex $keys.Sign)
    Assert-Equal 'a55574d3dfa58ceb4b6ae8390fd7da50281eadd7c7374589a1139984fc8dc55f' (Get-VivacLinkSignature $keys.Sign 'clip' '1700000000' ('0' * 32) $utf8.GetBytes('hola'))
    Assert-Equal '74cbdfe39f4c3b63b39465ee71fcddc8f86d4b0c53648895d9f4218d5988914f' (Get-VivacLinkAnswerSignature $keys.Sign ('0' * 32) $utf8.GetBytes('hola'))
    Assert-Equal '074c73367dfa6047' (Get-VivacLinkId $k)
}
Case 'a body sealed by the Linux half opens here, and one sealed here opens again' {
    $keys = Get-VivacLinkKeys ([Text.Encoding]::ASCII.GetBytes('k' * 32))
    $fromLinux = ConvertFrom-Hex '000102030405060708090a0b0c0d0e0fd57197019691b8d1996615a97a111b7b'
    Assert-Equal ('portapapeles ' + [char]0xF1) ($utf8.GetString((Unprotect-VivacLinkBody $keys.Seal $fromLinux)))
    $plain = $utf8.GetBytes('x' * 100)
    $sealed = Protect-VivacLinkBody $keys.Seal $plain
    Assert-Equal 128 $sealed.Length 'IV + 100 bytes padded to 112'
    Assert-Equal ('x' * 100) ($utf8.GetString((Unprotect-VivacLinkBody $keys.Seal $sealed)))
    Assert-True ((ConvertTo-VivacHex (Protect-VivacLinkBody $keys.Seal $plain)) -ne (ConvertTo-VivacHex $sealed)) 'a fresh IV every time'
    Assert-Throws { Unprotect-VivacLinkBody $keys.Seal (New-Object byte[] 20) } 'sealed'
}
Case 'a request is refused when stale, replayed or badly signed' {
    $k = (Get-VivacLinkKeys ([Text.Encoding]::ASCII.GetBytes('k' * 32))).Sign
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
Case 'the Wake-on-LAN packet is six 0xFF and the address sixteen times' {
    $p = Get-VivacMagicPacket ('0a:1b:2c' + ':3d:4e:5f')
    Assert-Equal 102 $p.Length
    Assert-Equal ('ffffffffffff' + ('0a1b2c3d4e5f' * 16)) (ConvertTo-VivacHex $p)
    Assert-Throws { Get-VivacMagicPacket 'not-a-mac' } 'hardware address'
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
$keys = Get-VivacLinkKeys $secret
Write-VivacLinkConf $secret 'gate' $port "127.0.0.1:$port"
$link = Join-Path $root 'bin\vivac-link.ps1'
$listener = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$link`"", '-Serve')

function Invoke-Link([string[]]$LinkArgs) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $link @LinkArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
# A request as given, for what the client never sends: sealed unless -Raw,
# signed with $Sign when given, else correctly.
function Send-Request([string]$Verb, [byte[]]$Plain, [string]$Time = [string](Get-VivacUnixTime), [string]$Nonce = (New-VivacLinkNonce), [string]$Sign = '', [switch]$Raw, [string]$Path = '') {
    $body = if ($Raw) { $Plain } else { Protect-VivacLinkBody $keys.Seal $Plain }
    if (-not $Sign) { $Sign = Get-VivacLinkSignature $keys.Sign $Verb $Time $Nonce $body }
    (Invoke-VivacLinkHttp '127.0.0.1' $port $Verb $body @{ 'X-Vivac-Time' = $Time; 'X-Vivac-Nonce' = $Nonce; 'X-Vivac-Sign' = $Sign } 5000 $Path).Status
}

try {
    # The listener is up when it answers.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try { [void](Invoke-VivacLinkHttp '127.0.0.1' $port 'ping' $null @{} 500); break } catch { Start-Sleep -Milliseconds 250 }
    }

    Case 'link: ping answers, sealed and signed, with the name and the system' {
        $r = Invoke-Link @('ping')
        Assert-Equal 0 $r.Code $r.Text
        $j = $r.Text | ConvertFrom-Json
        Assert-Equal 'gate' $j.name
        Assert-Equal 'windows' $j.os
        Assert-Equal 2 $j.protocol
        Assert-True ($null -ne $j.PSObject.Properties['mac']) 'the answer says the hardware address (empty on the loopback)'
    }
    Case 'link: a file lands in the inbox under a safe name, never overwriting' {
        $src = Join-Path $scratch 'hello world.txt'
        [IO.File]::WriteAllText($src, 'hola')
        Assert-Equal 0 (Invoke-Link @('send-file', $src)).Code
        Assert-Equal 0 (Invoke-Link @('send-file', $src)).Code
        Assert-Equal 'hola' ([IO.File]::ReadAllText((Join-Path $env:VIVAC_LINK_INBOX 'hello world.txt')))
        Assert-True (Test-Path -LiteralPath (Join-Path $env:VIVAC_LINK_INBOX 'hello world (2).txt')) 'second copy beside the first'
        $evil = [byte[]]($utf8.GetBytes('..\..\evil.txt') + 0 + $utf8.GetBytes('x'))
        Assert-Equal 200 (Send-Request 'file' $evil)
        Assert-True (Test-Path -LiteralPath (Join-Path $env:VIVAC_LINK_INBOX 'evil.txt')) 'the path is stripped'
        Assert-Equal 400 (Send-Request 'file' $utf8.GetBytes('no nul here'))
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
        Assert-Equal 200 (Send-Request 'clip' $utf8.GetBytes('portapapeles ' + [char]0xF1))
        Assert-Equal ('portapapeles ' + [char]0xF1) ([IO.File]::ReadAllText((Join-Path $env:VIVAC_LINK_SINK 'clip.txt'), $utf8))
    }
    Case 'link: 401 for a bad signature, a replay or a stale time; 400 unsealed; 413 too big; 404 unknown' {
        $body = $utf8.GetBytes('x')
        Assert-Equal 401 (Send-Request 'clip' $body -Sign ('0' * 64))
        $n = New-VivacLinkNonce
        Assert-Equal 200 (Send-Request 'clip' $body -Nonce $n)
        Assert-Equal 401 (Send-Request 'clip' $body -Nonce $n)
        Assert-Equal 401 (Send-Request 'clip' $body -Time ([string]((Get-VivacUnixTime) - 300)))
        Assert-Equal 400 (Send-Request 'clip' $body -Raw)
        Assert-Equal 400 (Send-Request 'clip' (New-Object byte[] (64KB + 1)))
        Assert-Equal 413 (Send-Request 'clip' (New-Object byte[] (64KB + (Get-VivacLinkSealRoom) + 1)) -Raw -Sign 'x')
        Assert-Equal 404 (Send-Request 'shell' $body -Sign 'x')
        Assert-Equal 404 (Send-Request 'clip' $body -Path '/v1/clip')
    }
    Case 'link: an answer not signed with the pairing''s keys is not taken' {
        $fake = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0)
        $fake.Start(); $fakePort = $fake.LocalEndpoint.Port
        Write-VivacLinkConf $secret 'gate' $port "127.0.0.1:$fakePort"
        $job = Start-Process powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $scratch 'fake.out') -RedirectStandardError (Join-Path $scratch 'fake.err') -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$link`"", 'ping')
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while (-not $fake.Pending() -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            $c = $fake.AcceptTcpClient(); $s = $c.GetStream()
            $buf = New-Object byte[] 65536; Start-Sleep -Milliseconds 300; [void]$s.Read($buf, 0, $buf.Length)
            $answer = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 32`r`nX-Vivac-Sign: $('0' * 64)`r`nConnection: close`r`n`r`n") + (New-Object byte[] 32)
            $s.Write($answer, 0, $answer.Length); $c.Close()
            [void]$job.WaitForExit(15000)
            Assert-True ($job.ExitCode -ne 0) 'the ping failed'
            Assert-True ([IO.File]::ReadAllText((Join-Path $scratch 'fake.err')) -match 'not trusted|no es de fiar') 'and said why'
        } finally {
            $fake.Stop()
            Write-VivacLinkConf $secret 'gate' $port "127.0.0.1:$port"
        }
    }
    # Both ends share one scratch profile here, so the listener's write (the
    # sender at 127.0.0.1, on the left) is followed by the client's (the peer
    # at 127.0.0.1, on the right).
    Case 'link: mouse places and trusts both sides'' lan-mouse, never turning it on' {
        $lm = Join-Path $env:VIVAC_LOCALAPPDATA 'lan-mouse'
        [void](New-Item -ItemType Directory -Force -Path $lm)
        $b64 = 'dml2YWMgbGluazogYSB0ZXN0'
        [IO.File]::WriteAllText((Join-Path $lm 'lan-mouse.pem'), "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----`n")
        $sha = [Security.Cryptography.SHA256]::Create()
        $fp = ((@($sha.ComputeHash([Convert]::FromBase64String($b64))) | ForEach-Object { $_.ToString('x2') }) -join ':')
        $r = Invoke-Link @('mouse', 'right')
        Assert-Equal 0 $r.Code $r.Text
        $cards = [IO.File]::ReadAllText((Join-Path $env:VIVAC_LINK_SINK 'cards.txt'))
        Assert-True ($cards -match '127\.0\.0\.1') "the listener placed the sender: $cards"
        $mc = [IO.File]::ReadAllText((Join-Path $env:VIVAC_LOCALAPPDATA 'vivac\mouse.conf'))
        Assert-True ($mc -match '(?m)^side=right') "the sender stored its side: $mc"
        Assert-True ($mc -match "(?m)^fingerprint=$fp") 'and the peer''s fingerprint'
        Assert-True ($mc -notmatch '(?m)^enabled=yes') 'pairing the mouse turned it on'
        Assert-True ((Invoke-Link @('mouse', 'sideways')).Code -ne 0) 'a side that is not one'
        Assert-Equal 400 (Send-Request 'mouse' $utf8.GetBytes('{"fingerprint":"zz","port":4242,"side":"left"}'))
    }
    Case 'link: wake sends the magic packet to the address a ping learnt' {
        Remove-Item -LiteralPath (Get-VivacLinkPeerMacPath) -Force -ErrorAction SilentlyContinue
        $r = Invoke-Link @('wake')
        Assert-True ($r.Code -ne 0 -and $r.Text -match 'not known yet|no se conoce') "wake without an address: $($r.Text)"
        $macPath = Get-VivacLinkPeerMacPath
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $macPath))
        [IO.File]::WriteAllText($macPath, ('0a:1b:2c' + ":3d:4e:5f`n"))
        $udp = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback, 0))
        try {
            $udp.Client.ReceiveTimeout = 10000
            $env:VIVAC_WAKE_TARGET = "127.0.0.1:$($udp.Client.LocalEndPoint.Port)"
            Assert-Equal 0 (Invoke-Link @('wake')).Code
            $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
            Assert-Equal ('ffffffffffff' + ('0a1b2c3d4e5f' * 16)) (ConvertTo-VivacHex $udp.Receive([ref]$ep))
        } finally { $udp.Close(); Remove-Item Env:\VIVAC_WAKE_TARGET -ErrorAction SilentlyContinue }
    }
} finally {
    if ($listener -and -not $listener.HasExited) { Stop-Process -Id $listener.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Complete-Cases
