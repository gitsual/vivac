# The Bluetooth devices Windows has paired, by name and address, for "pair
# once, both systems" (docs/bridge.md at the product root, section 7). The
# keys themselves are copied by the Linux half, which reads this system's
# registry from its own side; nothing here reads or writes them.

Set-StrictMode -Version 2.0

# Plug and Play names a paired device's node after its address:
# BTHENUM\DEV_<12 hex>\... for Classic, BTHLE\DEV_<12 hex>\... for Low Energy.
# The service nodes under a device (BTHENUM\{uuid}_...) are not devices.
function ConvertFrom-VivacBtPnpList($Devices) {
    $seen = @{}
    $rows = @()
    foreach ($d in @($Devices)) {
        if ($null -eq $d) { continue }
        if ([string]$d.InstanceId -notmatch '^(BTHENUM|BTHLE)\\DEV_([0-9A-Fa-f]{12})\\') { continue }
        $kind = if ($Matches[1] -eq 'BTHLE') { 'LE' } else { 'Classic' }
        $hex = $Matches[2].ToUpperInvariant()
        $address = (0..5 | ForEach-Object { $hex.Substring($_ * 2, 2) }) -join ':'
        if ($seen.ContainsKey("$kind $address")) { continue }
        $seen["$kind $address"] = $true
        $name = [string]$d.FriendlyName
        if (-not $name.Trim()) { $name = $address }
        $rows += [pscustomobject]@{ Name = $name; Address = $address; Kind = $kind }
    }
    @($rows | Sort-Object Name, Address)
}

# The rows as the report prints them: name, address, Classic or LE, aligned.
function Format-VivacBtReport($Rows) {
    $rows = @($Rows)
    if (-not $rows.Count) { return @() }
    $width = ($rows | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    @($rows | ForEach-Object { '  ' + $_.Name.PadRight($width) + '  ' + $_.Address + '  ' + $_.Kind })
}

Export-ModuleMember -Function *
