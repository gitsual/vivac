<#
.SYNOPSIS
  Detect what this machine is, as a small set of allowlisted facts.

.DESCRIPTION
  Detection is split in two so it can be tested without the hardware:
    1. a snapshot: the raw CIM/WMI answers, as plain data
    2. a classification: snapshot -> facts, a pure function
  tests/fixtures/<machine>/snapshot.json are hand-written snapshots of
  machines this one is not, and tests/golden/<machine>/hardware-facts the
  facts they must produce.

  Only the keys in $AllowedKeys can come out. That allowlist is what keeps
  serial numbers, MAC addresses, model names and the computer name out of a
  file that ends up attached to bug reports.

.PARAMETER Emit
  Write the facts to %APPDATA%\vivac\hardware-facts (default: print them).
.PARAMETER Snapshot
  Classify this snapshot JSON instead of asking the machine.
.PARAMETER DumpSnapshot
  Print the raw snapshot as JSON, to write a new fixture from.
#>
[CmdletBinding()]
param(
    [switch]$Emit,
    [string]$Snapshot,
    [switch]$DumpSnapshot
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force

$AllowedKeys = @('FACTS_SCHEMA', 'chassis', 'virt', 'gpu_vendors', 'has_battery',
    'has_wifi', 'has_bluetooth', 'has_backlight', 'monitor_count', 'max_scale')

function Get-MachineSnapshot {
    $ea = 'SilentlyContinue'
    $enclosure = Get-CimInstance Win32_SystemEnclosure -ErrorAction $ea
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction $ea
    $video = @(Get-CimInstance Win32_VideoController -ErrorAction $ea | ForEach-Object { [string]$_.PNPDeviceID })
    $batteries = @(Get-CimInstance Win32_Battery -ErrorAction $ea).Count
    $media = @(Get-NetAdapter -Physical -ErrorAction $ea | ForEach-Object { [string]$_.PhysicalMediaType })
    $bluetooth = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction $ea |
        Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -notmatch 'Enumerator|RFCOMM|LE Generic' }).Count
    $brightness = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction $ea).Count
    Add-Type -AssemblyName System.Windows.Forms
    $screens = @([System.Windows.Forms.Screen]::AllScreens).Count
    $dpi = 96
    try {
        $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
        $dpi = [int]$g.DpiX
        $g.Dispose()
    } catch { }
    $chassisTypes = @()
    if ($enclosure) { $chassisTypes = @($enclosure.ChassisTypes | ForEach-Object { [int]$_ }) }
    $model = ''
    $maker = ''
    if ($system) { $model = [string]$system.Model; $maker = [string]$system.Manufacturer }
    [ordered]@{
        chassis_types = $chassisTypes
        model         = $model
        manufacturer  = $maker
        video_pnp_ids = $video
        battery_count = $batteries
        adapter_media = $media
        bluetooth_radios = $bluetooth
        brightness_monitors = $brightness
        screen_count  = $screens
        dpi           = $dpi
    }
}

# The classification. Model and manufacturer are read to recognise a virtual
# machine and never copied into a fact.
function ConvertTo-MachineFacts($s) {
    $virt = 'none'
    $id = "$($s.manufacturer) $($s.model)"
    if ($id -match 'VMware') { $virt = 'vmware' }
    elseif ($id -match 'VirtualBox|innotek') { $virt = 'virtualbox' }
    elseif ($id -match 'QEMU|KVM|Bochs') { $virt = 'qemu' }
    elseif ($id -match 'Microsoft Corporation Virtual Machine') { $virt = 'hyperv' }

    $laptop = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
    $desktop = @(3, 4, 5, 6, 7, 13, 15, 16, 24, 35, 36)
    $chassis = 'unknown'
    if ($virt -ne 'none') { $chassis = 'vm' }
    elseif (@($s.chassis_types | Where-Object { $laptop -contains $_ }).Count) { $chassis = 'laptop' }
    elseif (@($s.chassis_types | Where-Object { $desktop -contains $_ }).Count) { $chassis = 'desktop' }

    $vendors = New-Object System.Collections.Generic.List[string]
    foreach ($pnp in @($s.video_pnp_ids)) {
        $v = switch -Regex ($pnp) {
            'VEN_10DE' { 'nvidia'; break }
            'VEN_1002' { 'amd'; break }
            'VEN_8086' { 'intel'; break }
            'VEN_(1414|15AD|80EE|1AF4|1B36|1234)' { 'virtual'; break }
            default { $null }
        }
        if ($v -and -not $vendors.Contains($v)) { $vendors.Add($v) }
    }
    $gpu = 'none'
    if ($vendors.Count) { $gpu = (@($vendors) | Sort-Object) -join ' ' }

    $yes = { param($b) if ($b) { 'yes' } else { 'no' } }
    $scale = [Math]::Round([double]$s.dpi / 96, 2)
    [ordered]@{
        FACTS_SCHEMA  = '1'
        chassis       = $chassis
        virt          = $virt
        gpu_vendors   = $gpu
        has_battery   = & $yes ([int]$s.battery_count -gt 0)
        has_wifi      = & $yes (@($s.adapter_media | Where-Object { $_ -match '802\.11|Wireless' }).Count -gt 0)
        has_bluetooth = & $yes ([int]$s.bluetooth_radios -gt 0)
        has_backlight = & $yes ([int]$s.brightness_monitors -gt 0)
        monitor_count = [string][Math]::Max(1, [int]$s.screen_count)
        max_scale     = ([string]$scale).Replace(',', '.')
    }
}

function Format-Facts($facts) {
    $lines = @('# Hardware facts, detected by scripts/hardware-facts.ps1. Do not edit:',
        '# put a corrected key in hardware-facts.override beside this file instead.')
    foreach ($key in $facts.Keys) {
        if ($AllowedKeys -notcontains $key) { throw "hardware-facts: '$key' is not an allowed fact" }
        $lines += "$key=$($facts[$key])"
    }
    ($lines -join "`n") + "`n"
}

if ($Snapshot) {
    $raw = Get-Content -Raw -LiteralPath $Snapshot | ConvertFrom-Json
    $snap = [ordered]@{}
    foreach ($p in $raw.PSObject.Properties) { $snap[$p.Name] = $p.Value }
} else {
    $snap = Get-MachineSnapshot
}
if ($DumpSnapshot) { $snap | ConvertTo-Json; return }

$text = Format-Facts (ConvertTo-MachineFacts $snap)
if ($Emit) {
    $path = (Get-VivacPaths).Facts
    Write-VivacFile -Path $path -Text $text
    Write-Host (T 'facts.written' @($path))
} else {
    # To the pipeline, not the console: deploy.ps1 and bootstrap.ps1 capture it.
    $text.TrimEnd("`n")
}
