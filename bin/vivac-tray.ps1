<#
.SYNOPSIS
  What the notification area used to answer for, for the bar.

.DESCRIPTION
    -Status          one line of JSON: the Bluetooth radio, a restart Windows
                     Update is waiting for, and the resident antivirus that is
                     not Defender (Defender has its own shield)
    -Updates         one line of JSON: how many updates are waiting
    -Bluetooth       turns the Bluetooth radio on or off
    -Pair <address>  pairs with a Bluetooth device (12 hex digits), with
                     Windows' own prompt if it asks for a code, then a vivac
                     notification; lib/Bluetooth.psm1 starts it detached
    -Eject <X:>      safely removes a drive, then a vivac notification
    -Open <what>     updates or antivirus: the window that manages it

  The bar shows these in place of the tray icons, which it no longer draws:
  a program's own icon there is not vivac's. zpack.json grants exactly these
  command lines. -Updates reads Windows Update's own cache rather than asking
  the servers, and still takes seconds, so the bar asks for it seldom.
#>
param(
    [switch]$Status,
    [switch]$Updates,
    [switch]$Bluetooth,
    [ValidatePattern('^[0-9A-Fa-f]{12}$')][string]$Pair,
    [ValidatePattern('^[A-Za-z]:$')][string]$Eject,
    [ValidateSet('updates', 'antivirus')][string]$Open
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Bluetooth.psm1') -Force

# Malwarebytes is the one this machine runs; another product is one more row.
$antivirus = @(
    @{ Name = 'Malwarebytes'; Service = 'MBAMService'; Exe = (Join-Path $env:ProgramFiles 'Malwarebytes\Anti-Malware\Malwarebytes.exe') }
)

function Write-Json($Value) {
    # The bar reads stdout as UTF-8; Windows PowerShell writes the console's
    # code page unless told otherwise.
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    [Console]::Out.Write(($Value | ConvertTo-Json -Compress))
}

if ($Status) {
    $bt = Get-VivacBluetoothState
    $av = $null
    foreach ($a in $antivirus) {
        if (-not (Test-Path -LiteralPath $a.Exe)) { continue }
        $svc = Get-Service -Name $a.Service -ErrorAction SilentlyContinue
        $av = [ordered]@{ name = $a.Name; running = [bool]($svc -and $svc.Status -eq 'Running') }
        break
    }
    $reboot = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    Write-Json ([ordered]@{ bluetooth = $bt; reboot = $reboot; antivirus = $av })
    return
}

if ($Updates) {
    $titles = @()
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $searcher.Online = $false
        foreach ($u in $searcher.Search('IsInstalled=0 and IsHidden=0').Updates) { $titles += [string]$u.Title }
    } catch { $titles = @() }
    Write-Json ([ordered]@{ count = $titles.Count; titles = $titles })
    return
}

if ($Bluetooth) {
    $on = Get-VivacBluetoothState
    if ($null -ne $on) { [void](Set-VivacBluetoothState (-not $on)) }
    return
}

if ($Pair) {
    Import-VivacBluetooth
    $address = [Convert]::ToUInt64($Pair, 16)
    $name = @([VivacBluetooth]::Devices($false, 0) | Where-Object { $_.Address -eq $address } | ForEach-Object { $_.Name }) + [VivacBluetooth]::FormatAddress($address) | Select-Object -First 1
    # The first notice goes through a process of its own: a notification here
    # ends this thread's dispatcher, and the outcome still has to be shown.
    Invoke-Detached (Join-Path $PSScriptRoot 'vivac.ps1') @('notify', 'Bluetooth', (T 'bt.pairing' @($name)))
    $rc = [VivacBluetooth]::Pair($address, [IntPtr]::Zero)
    if ($rc -eq 0) { Show-Notification 'Bluetooth' (T 'bt.paired' @($name)) }
    else { Show-Notification 'Bluetooth' (T 'bt.pair_failed' @($name, $rc)) }
    return
}

if ($Eject) {
    $drive = $Eject.ToUpperInvariant()
    # The shell's Eject verb is the taskbar's "safely remove": it flushes and
    # dismounts, and refuses, with its own dialog, a drive still in use.
    $item = (New-Object -ComObject Shell.Application).Namespace(17).ParseName("$drive\")
    if (-not $item) { Show-Notification 'USB' (T 'bar.eject_gone' @($drive)); return }
    $item.InvokeVerb('Eject')
    Start-Sleep -Milliseconds 1500
    if (Test-Path -LiteralPath "$drive\") { Show-Notification 'USB' (T 'bar.eject_busy' @($drive)) }
    else { Show-Notification 'USB' (T 'bar.eject_done' @($drive)) }
    return
}

switch ($Open) {
    'updates' { Start-Process 'ms-settings:windowsupdate' }
    'antivirus' {
        foreach ($a in $antivirus) { if (Test-Path -LiteralPath $a.Exe) { Start-Process -FilePath $a.Exe; break } }
    }
}
