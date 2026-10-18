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
