<#
.SYNOPSIS
  The Bluetooth devices paired on this Windows, for pairing them once for
  both systems of a dual boot.

.DESCRIPTION
  The Windows side of docs/bridge.md, "Bluetooth across the dual boot". A
  device paired on both systems keeps one key per system, and only the last
  pairing's works. The Linux half copies Windows' keys into BlueZ
  (vivac-bt-sync there), reading this partition from its own side, so the
  order is: pair on Linux, pair here, restart in Linux, take the pairings
  from Windows in the bridge menu. Nothing here changes anything.

    -Report    list the paired devices: name, address, Classic or LE (the
               default)

  Shut Windows down fully before restarting in Linux (Shift and Shut down,
  or Restart): a hibernated Windows, or one shut down with Fast Startup, is
  refused by the Linux half, since its registry on disk may be old.
#>
[CmdletBinding()]
param([switch]$Report)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\BtSync.psm1') -Force

$rows = @(ConvertFrom-VivacBtPnpList @(Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue))
if (-not $rows.Count) {
    T 'btsync.none'
    exit 0
}
T 'btsync.header' @($rows.Count)
Format-VivacBtReport $rows
''
T 'btsync.hint'
