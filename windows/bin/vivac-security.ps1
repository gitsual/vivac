<#
.SYNOPSIS
  Defender and Malwarebytes, for the bar and the security surface.

.DESCRIPTION
    -Status   one line of JSON for the bar's shield, for both antivirus:
              state (ok, warn, alert), the words beside it, its tooltip, and
              antivirus/malwarebytes (null without Malwarebytes)
    -Scan     a quick scan, then a vivac notification with what it found
    -Update   a signature update, then a vivac notification

  The bar runs -Status every few minutes (zpack.json grants exactly that
  command line); the surface in lib/Security.psm1 starts -Scan and -Update in
  a process of their own so they outlive its window.
#>
param([switch]$Status, [switch]$Scan, [switch]$Update)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
Import-Module (Join-Path $root 'lib\Security.psm1') -Force

if ($Status) {
    # The bar reads stdout as UTF-8; Windows PowerShell writes the console's
    # code page unless told otherwise, and the strings carry accents.
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    [Console]::Out.Write(((Get-VivacSecuritySummary) | ConvertTo-Json -Compress))
    return
}

# MpCmdRun lives with the Defender platform that is current, which moves on
# every platform update; the copy under Program Files is the fallback.
function Get-MpCmdRun {
    $loc = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name InstallLocation -ErrorAction SilentlyContinue)
    if ($loc -and (Test-Path -LiteralPath (Join-Path $loc.InstallLocation 'MpCmdRun.exe'))) { return (Join-Path $loc.InstallLocation 'MpCmdRun.exe') }
    Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
}

function Invoke-MpCmdRun([string[]]$Arguments) {
    $proc = Start-Process -FilePath (Get-MpCmdRun) -ArgumentList $Arguments -WindowStyle Hidden -PassThru -Wait
    $proc.ExitCode
}

# The first notice goes through a process of its own: a notification here
# ends this thread's dispatcher, and the second one still has to be shown.
function Send-Notice([string]$Body) {
    Start-Process -FilePath 'conhost.exe' -WindowStyle Hidden -ArgumentList @('--headless', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $PSScriptRoot 'vivac.ps1')`"", 'notify', 'Defender', $Body) | Out-Null
}

if ($Scan) {
    Send-Notice (T 'security.scan_started')
    $code = Invoke-MpCmdRun @('-Scan', '-ScanType', '1')
    $threats = @((Get-VivacSecurityStatus).Threats)
    if ($threats.Count) { $msg = T 'security.scan_found' @($threats.Count) }
    elseif ($code -eq 0) { $msg = T 'security.scan_clean' }
    else { $msg = T 'security.scan_failed' @($code) }
    Show-Notification 'Defender' $msg
    return
}

if ($Update) {
    Send-Notice (T 'security.update_started')
    $code = Invoke-MpCmdRun @('-SignatureUpdate')
    if ($code -eq 0) { $msg = T 'security.update_done' } else { $msg = T 'security.update_failed' @($code) }
    Show-Notification 'Defender' $msg
    return
}

Show-Security
