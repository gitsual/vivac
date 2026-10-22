# Other programs' notifications: what the card shows is read right from the
# XML Windows keeps, programs are named as a person knows them, and the card
# builds in the palette.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Toasts.psm1') -Force

$logo = Join-Path $env:TEMP 'vivac-toast-test.png'
[IO.File]::WriteAllBytes($logo, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=='))

Case 'title, body and logo come from a ToastGeneric binding' {
    $x = "<?xml version=`"1.0`"?><toast launch=`"go`"><visual><binding template=`"ToastGeneric`"><text hint-maxLines=`"1`">Plugin updates available</text><text>Calculator, URL</text><image src=`"$logo`" placement=`"appLogoOverride`"/></binding></visual><actions><action content=`"Update`" arguments=`"x`"/></actions></toast>"
    $c = ConvertFrom-ToastPayload $x
    Assert-Equal 'Plugin updates available' $c.Title
    Assert-Equal 'Calculator, URL' $c.Body
    Assert-Equal $logo $c.Image
    Assert-Equal 'go' $c.Launch
}
Case 'CDATA text, several body lines, and a logo given as a file URL' {
    $url = 'file:///' + ($logo -replace '\\', '/')
    $x = "<toast><visual><binding template=`"ToastGeneric`"><image src=`"$url`" placement=`"appLogoOverride`"/><text><![CDATA[Busca fotos]]></text><text><![CDATA[Uno]]></text><text>Dos</text></binding></visual></toast>"
    $c = ConvertFrom-ToastPayload $x
    Assert-Equal 'Busca fotos' $c.Title
    Assert-Equal "Uno`nDos" $c.Body
    Assert-Equal $logo $c.Image
}
Case 'a logo that is not a local file, or no XML at all, leaves the card plain' {
    $c = ConvertFrom-ToastPayload '<toast><visual><binding template="ToastGeneric"><text>Hi</text><image src="ms-appx:///logo.png" placement="appLogoOverride"/></binding></visual></toast>'
    Assert-Equal 'Hi' $c.Title
    Assert-Equal '' $c.Image
    $bad = ConvertFrom-ToastPayload 'not xml'
    Assert-Equal '' $bad.Title
}
Case 'a program known only by its path is named after its file' {
    $exe = (Get-Command powershell.exe).Source
    $aumid = $exe -replace '\\', '/'
    Assert-Equal $exe (Get-ToastAppPath $aumid)
    Assert-True ((Get-ToastAppName $aumid) -match 'PowerShell') 'the file description names it'
    Assert-Equal $null (Get-ToastAppPath 'Microsoft.WindowsStore_8wekyb3d8bbwe!App')
}
Case 'the card is a vivac window that never takes the focus' {
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    $w = New-VivacNotification 'Title' 'Body' 'App' $logo
    Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
    Assert-Equal $false $w.ShowActivated
    Assert-True $w.Tag.Close 'a close mark'
    Assert-True $w.Tag.Progress 'a time line'
}
Remove-Item -LiteralPath $logo -Force -ErrorAction SilentlyContinue
Complete-Cases
