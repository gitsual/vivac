# The network panel: the profiles it hands Windows, the bars and the
# security it shows, and that it builds in every theme. Nothing here touches
# the network: no scan, no connection, no radio.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Network.psm1') -Force

Case 'a WPA2 profile carries the name, its hex form and the key, escaped' {
    $xml = [xml](New-VivacWifiProfileXml 'Casa & <Jardin>' 'clave"segura' 7 4)
    $ns = New-Object Xml.XmlNamespaceManager $xml.NameTable
    $ns.AddNamespace('w', 'http://www.microsoft.com/networking/WLAN/profile/v1')
    Assert-Equal 'Casa & <Jardin>' $xml.SelectSingleNode('//w:name', $ns).InnerText
    $hex = -join @([Text.Encoding]::UTF8.GetBytes('Casa & <Jardin>') | ForEach-Object { $_.ToString('X2') })
    Assert-Equal $hex $xml.SelectSingleNode('//w:SSID/w:hex', $ns).InnerText
    Assert-Equal 'WPA2PSK' $xml.SelectSingleNode('//w:authentication', $ns).InnerText
    Assert-Equal 'AES' $xml.SelectSingleNode('//w:encryption', $ns).InnerText
    Assert-Equal 'clave"segura' $xml.SelectSingleNode('//w:keyMaterial', $ns).InnerText
    Assert-Equal 'passPhrase' $xml.SelectSingleNode('//w:keyType', $ns).InnerText
}
Case 'an accented name is hex-encoded as UTF-8' {
    $ssid = 'Se' + [char]0x00F1 + 'al'
    $xml = [xml](New-VivacWifiProfileXml $ssid '12345678' 7 4)
    Assert-True ($xml.OuterXml -match '<hex>5365C3B1616C</hex>') 'UTF-8 hex'
}
Case 'WPA3, older WPA with TKIP, and open networks get their own security' {
    Assert-True ((New-VivacWifiProfileXml 'a' '12345678' 9 4) -match '<authentication>WPA3SAE</authentication>')
    $wpa = New-VivacWifiProfileXml 'a' '12345678' 4 2
    Assert-True ($wpa -match '<authentication>WPAPSK</authentication>' -and $wpa -match '<encryption>TKIP</encryption>')
    $open = New-VivacWifiProfileXml 'a' '' 1 0
    Assert-True ($open -match '<authentication>open</authentication>' -and $open -notmatch 'sharedKey') 'open, no key'
}
Case 'keys Windows would refuse are refused here first; a 64-digit hex key is a raw key' {
    Assert-Throws { New-VivacWifiProfileXml 'a' 'short' 7 4 }
    Assert-Throws { New-VivacWifiProfileXml 'a' ('x' * 64) 7 4 }
    Assert-True ((New-VivacWifiProfileXml 'a' ('ab' * 32) 7 4) -match '<keyType>networkKey</keyType>')
    Assert-Throws { New-VivacWifiProfileXml 'a' '12345678' 6 4 } 'left to Windows'
}
Case 'what the panel joins itself and what it leaves to Windows' {
    Assert-Equal 'open' (Get-VivacWifiAuthKind 1)
    Assert-Equal 'psk' (Get-VivacWifiAuthKind 7)
    Assert-Equal 'psk' (Get-VivacWifiAuthKind 4)
    Assert-Equal 'sae' (Get-VivacWifiAuthKind 9)
    foreach ($a in 2, 6, 8, 10, 11) { Assert-Equal 'other' (Get-VivacWifiAuthKind $a) "auth $a" }
    Assert-Equal 'WPA2' (Get-VivacWifiAuthLabel 7)
    Assert-Equal 'WPA3' (Get-VivacWifiAuthLabel 9)
    Assert-Equal '' (Get-VivacWifiAuthLabel 1)
}
Case 'signal bars and speeds read as Windows writes them' {
    Assert-Equal 59137 ([int](Get-VivacWifiGlyph 100)) 'full bars'
    Assert-Equal 59508 ([int](Get-VivacWifiGlyph 60)) 'three bars'
    Assert-Equal 59507 ([int](Get-VivacWifiGlyph 30)) 'two bars'
    Assert-Equal 59506 ([int](Get-VivacWifiGlyph 5)) 'one bar'
    Assert-Equal '390 Mbps' (Format-VivacSpeed 390)
    Assert-Equal '1 Gbps' (Format-VivacSpeed 1000)
    Assert-Equal '2.5 Gbps' ((Format-VivacSpeed 2500) -replace ',', '.')
}
Case 'channels and bands from the centre frequency' {
    Import-VivacNetwork
    Assert-Equal 1 ([VivacNetwork]::ChannelOf(2412))
    Assert-Equal 14 ([VivacNetwork]::ChannelOf(2484))
    Assert-Equal 44 ([VivacNetwork]::ChannelOf(5220))
    Assert-Equal 1 ([VivacNetwork]::ChannelOf(5955))
    Assert-Equal '5 GHz' ([VivacNetwork]::BandOf(5220))
    Assert-Equal '6 GHz' ([VivacNetwork]::BandOf(5955))
}

Import-Module (Join-Path $root 'lib\PanelKit.psm1') -Force
Import-Module (Join-Path $root 'lib\NetIcons.psm1') -Force
Case 'the network icons join PanelKit icons and every one parses' {
    foreach ($n in 'wifi', 'ethernet', 'bluetooth', 'headphones', 'keyboard', 'gamepad', 'speaker', 'trash', 'plug', 'sliders', 'bolt', 'target', 'unlock') {
        $el = ConvertTo-PanelElement (Get-NetIconXaml $n 16 'FFFFFF')
        Assert-True ($el -is [Windows.Controls.Viewbox]) "icon $n"
    }
    Assert-True ((Get-PanelIconXaml 'wifi' 12 'FFFFFF') -match 'Path') 'PanelKit knows wifi once the icons are added'
}
Case 'signal bars light up as the signal grows' {
    Assert-Equal 4 (Get-NetBarCount 100)
    Assert-Equal 3 (Get-NetBarCount 60)
    Assert-Equal 2 (Get-NetBarCount 30)
    Assert-Equal 1 (Get-NetBarCount 5)
    Assert-Equal 0 (Get-NetBarCount 0)
}
Case 'a sparkline puts the highest sample at the top and the lowest at the bottom' {
    $pts = @(Get-VivacSparkPoints ([double[]]@(10, 20, 15)) 100 44)
    Assert-Equal 3 $pts.Count
    Assert-Equal 0 $pts[0].X
    Assert-Equal 100 $pts[2].X
    Assert-True ($pts[1].Y -lt $pts[0].Y -and $pts[1].Y -lt $pts[2].Y) 'the peak is highest'
    $flat = @(Get-VivacSparkPoints ([double[]]@(5)) 100 44)
    Assert-Equal 2 $flat.Count 'one sample is a flat line'
    Assert-Equal $flat[0].Y $flat[1].Y
    Assert-Equal 0 @(Get-VivacSparkPoints ([double[]]@()) 100 44).Count
}
Case 'only a machine with two Wi-Fi adapters lists them, naming the one that carries' {
    $one = [pscustomobject]@{ HasInterface = $true; Interface = [guid]'11111111-1111-1111-1111-111111111111'
        Adapters = @([pscustomobject]@{ Wifi = $true; Id = '{11111111-1111-1111-1111-111111111111}'; Name = 'Wi-Fi'; Description = 'A'; Up = $true }) }
    Assert-Equal 0 @(Get-VivacWifiAdapters $one).Count
    $two = [pscustomobject]@{ HasInterface = $true; Interface = [guid]'22222222-2222-2222-2222-222222222222'
        Adapters = @([pscustomobject]@{ Wifi = $true; Id = '{11111111-1111-1111-1111-111111111111}'; Name = 'Wi-Fi'; Description = 'A'; Up = $true },
            [pscustomobject]@{ Wifi = $true; Id = '{22222222-2222-2222-2222-222222222222}'; Name = 'Wi-Fi 2'; Description = 'B'; Up = $true },
            [pscustomobject]@{ Wifi = $false; Id = '{3}'; Name = 'Ethernet'; Description = 'E'; Up = $true }) }
    $r = @(Get-VivacWifiAdapters $two)
    Assert-Equal 2 $r.Count
    Assert-True ((-not $r[0].Carries) -and $r[1].Carries) 'the second one carries'
}

$dir = New-TempProfile
try {
    foreach ($name in Get-VivacCatalogue) {
        Case "the network panel builds in $name" {
            Set-VivacSetting theme $name
            Import-Module (Join-Path $root 'lib\Network.psm1') -Force
            $w = Show-Network -NoShow
            Assert-True ($w -is [Windows.Window]) 'a window'
            Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
            $w.Close()
        }
    }
} finally { Remove-TempProfile $dir }
Complete-Cases
