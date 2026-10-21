<#
.SYNOPSIS
  The phone, through KDE Connect: what the bar and the menu ask of it.

.DESCRIPTION
    -Status          one line of JSON for the bar: the paired phones KDE
                     Connect reaches now ({"phones":[{"id","name"}]}), or
                     null without KDE Connect
    -Ring            make the phone ring
    -SendFile        choose a file and send it to the phone
    -SendClipboard   send this clipboard to the phone
    -Manage          open KDE Connect, where phones are paired and unpaired

  -Device ID (and -Name, for what is said) picks the phone. The menu starts
  these on their own, so the menu never waits on the phone; how each went is
  said in a notification. zpack.json grants the bar -Status and nothing else.
  docs/bridge.md at the root of the product, "The phone".
#>
param(
    [switch]$Status,
    [switch]$Ring,
    [switch]$SendFile,
    [switch]$SendClipboard,
    [switch]$Manage,
    [string]$Device = '',
    [string]$Name = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Phone.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

if ($Status) {
    # The bar reads stdout as UTF-8; Windows PowerShell writes the console's
    # code page unless told otherwise.
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $s = Get-VivacPhoneStatus
    if ($null -eq $s) { [Console]::Out.Write('null'); return }
    [Console]::Out.Write((ConvertTo-Json -InputObject $s -Compress -Depth 4))
    return
}

# The gates set VIVAC_PHONE_SINK to a file: what would reach the screen is
# written there instead.
function Say([string]$Body) {
    if ($env:VIVAC_PHONE_SINK) { Add-Content -LiteralPath $env:VIVAC_PHONE_SINK -Value "notify|$Body" -Encoding UTF8; return }
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    Show-Notification (T 'phone.title') $Body
}

if ($Manage) {
    $app = Get-VivacPhoneApp
    if ($app) { Start-Process -FilePath $app } else { Say (T 'phone.not_installed') }
    return
}

if (-not (Get-VivacPhoneCli)) { Say (T 'phone.not_installed'); exit 1 }
if (-not (Test-VivacPhoneId $Device)) { throw 'vivac-phone: -Device needs a device id' }
if (-not $Name) { $Name = $Device }

function Send-Phone([string[]]$CliArgs, [string]$Done) {
    $r = Invoke-VivacPhoneCli (@('--device', $Device) + $CliArgs)
    if ($r -and $r.Code -eq 0) { Say $Done } else { Say (T 'phone.failed' @($Name)); exit 1 }
}

if ($Ring) { Send-Phone @('--ring') (T 'phone.ringing' @($Name)); return }
if ($SendClipboard) { Send-Phone @('--send-clipboard') (T 'phone.sent' @($Name)); return }
if ($SendFile) {
    # VIVAC_PHONE_FILE stands in for the dialog in the gates.
    $file = $env:VIVAC_PHONE_FILE
    if (-not $file) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = T 'phone.pick_file'
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
        $file = $dialog.FileName
    }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
    Send-Phone @('--share', ([IO.Path]::GetFullPath($file))) (T 'phone.sent' @($Name))
    return
}
throw 'vivac-phone: -Status, -Ring, -SendFile, -SendClipboard or -Manage'
