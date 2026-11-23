# The Bluetooth panel: it builds, shows the design's groups for sample
# devices (connected, paired, nearby) and the radio's switch in its header.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\PanelKit.psm1') -Force
Import-Module (Join-Path $root 'lib\BtIcons.psm1') -Force
Import-Module (Join-Path $root 'lib\Bluetooth.psm1') -Force
Import-VivacBluetooth

Case 'the stroke icons are registered in the panel kit' {
    Register-BtIcons
    foreach ($n in 'bluetooth', 'headphones', 'keyboard', 'gamepad', 'speaker', 'trash', 'plug', 'sliders', 'battery') {
        Assert-True ((Get-PanelIconXaml $n 16 'FFFFFF') -match '<Path') "icon $n draws"
    }
}
Case 'the Bluetooth panel builds, titled vivac, with the radio switch in its header' {
    $w = Show-Bluetooth -NoShow
    Assert-True ($w -is [Windows.Window]) 'a window'
    Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
    Assert-True ($w.FindName('HeaderRight').Children.Count -eq 1) 'the switch'
    Assert-True ($null -ne $w.FindName('More')) 'the Windows settings foot'
    $w.Close()
}
Complete-Cases
