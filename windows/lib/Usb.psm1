Set-StrictMode -Version 2.0

function Remove-VivacUsbDrive {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z]:$')][string]$Drive)

    $part = Get-Partition -DriveLetter $Drive.Substring(0, 1) -ErrorAction Stop
    $disk = $part | Get-Disk -ErrorAction Stop
    if ($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem) { throw 'Only external USB disks can be safely removed here.' }
    $physical = Get-CimInstance Win32_DiskDrive -Filter "Index=$($disk.Number)" -ErrorAction Stop
    # Eject the USB device, not its non-removable USBSTOR disk child. Never
    # walk up to a hub or controller, which could disconnect other disks.
    $parent = [string](Get-PnpDeviceProperty -InstanceId $physical.PNPDeviceID -KeyName DEVPKEY_Device_Parent -ErrorAction Stop).Data
    if ($parent -notmatch '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\') { throw 'Cannot identify a dedicated USB device for this disk.' }
    $capabilities = (Get-PnpDeviceProperty -InstanceId $parent -KeyName DEVPKEY_Device_Capabilities -ErrorAction Stop).Data
    if (-not ($capabilities -band 4)) { throw 'Windows does not identify this USB device as removable.' }
    if (-not $PSCmdlet.ShouldProcess("$Drive $($disk.FriendlyName)", 'Request safe USB removal')) { return }

    if (-not ('VivacUsbNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class VivacUsbNative {
    [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern uint CM_Locate_DevNodeW(out uint node, string id, uint flags);
    [DllImport("cfgmgr32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    public static extern uint CM_Request_Device_EjectW(uint node, out uint veto, StringBuilder name, uint length, uint flags);
}
'@
    }
    [uint32]$node = 0
    $result = [VivacUsbNative]::CM_Locate_DevNodeW([ref]$node, $parent, 0)
    if ($result -ne 0) { throw ('CM_Locate_DevNode failed: 0x{0:X}' -f $result) }
    [uint32]$veto = 0
    $reason = New-Object Text.StringBuilder 1024
    $result = [VivacUsbNative]::CM_Request_Device_EjectW($node, [ref]$veto, $reason, 1024, 0)
    [pscustomobject]@{ Success = ($result -eq 0); Code = $result; Veto = $veto; Reason = $reason.ToString(); Drive = $Drive }
}

Export-ModuleMember -Function Remove-VivacUsbDrive
