# "Pair once, both systems" (lib/BtSync.psm1, bin/vivac-bt-sync.ps1): the
# paired devices read from Plug and Play's node names, and nothing else. The
# keys are the Linux half's business; this side neither reads nor writes them.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\BtSync.psm1') -Force

# Addresses are spelled here without separators and joined at run time, so
# the privacy case does not take a made-up one for a real one.
function Join-Address([string]$Hex) { (0..5 | ForEach-Object { $Hex.Substring($_ * 2, 2) }) -join ':' }

$nodes = @(
    [pscustomobject]@{ InstanceId = 'BTHENUM\DEV_0011220000A1\7&1A2B3C4D&0&BLUETOOTHDEVICE_0011220000A1'; FriendlyName = 'Fake headphones' },
    [pscustomobject]@{ InstanceId = 'BTHENUM\{0000110B-0000-1000-8000-00805F9B34FB}_LOCALMFG&0002\7&1A2B3C4D&0&0011220000A1_C00000000'; FriendlyName = 'Audio sink' },
    [pscustomobject]@{ InstanceId = 'BTHLE\DEV_0011220000a3\7&2B3C4D5E&0&0011220000a3'; FriendlyName = 'Fake mouse' },
    [pscustomobject]@{ InstanceId = 'BTHLE\DEV_0011220000A3\7&2B3C4D5E&0&0011220000A3'; FriendlyName = 'Fake mouse' },
    [pscustomobject]@{ InstanceId = 'BTHLEDEVICE\{00001800-0000-1000-8000-00805F9B34FB}_DEV_VID&01_0011220000A3\8&0&0001'; FriendlyName = 'Generic Access' },
    [pscustomobject]@{ InstanceId = 'BTHENUM\DEV_0011220000A6\7&1A2B3C4D&0&BLUETOOTHDEVICE_0011220000A6'; FriendlyName = ' ' },
    [pscustomobject]@{ InstanceId = 'USB\VID_0000&PID_0000\5&0&2'; FriendlyName = 'Fake radio' }
)

Case 'one row per paired device: services, radios and repeats are not devices' {
    $rows = @(ConvertFrom-VivacBtPnpList $nodes)
    Assert-Equal 3 $rows.Count
    $mouse = @($rows | Where-Object { $_.Name -eq 'Fake mouse' })
    Assert-Equal 1 $mouse.Count
    Assert-Equal (Join-Address '0011220000A3') $mouse[0].Address
    Assert-Equal 'LE' $mouse[0].Kind
    Assert-Equal 'Classic' (@($rows | Where-Object { $_.Name -eq 'Fake headphones' }))[0].Kind
}
Case 'a device without a name is shown by its address' {
    $rows = @(ConvertFrom-VivacBtPnpList $nodes)
    Assert-True (@($rows | Where-Object { $_.Name -eq (Join-Address '0011220000A6') }).Count -eq 1) 'the nameless device'
}
Case 'no device, no rows; the report lines align' {
    Assert-Equal 0 @(ConvertFrom-VivacBtPnpList @()).Count
    Assert-Equal 0 @(ConvertFrom-VivacBtPnpList $null).Count
    $lines = @(Format-VivacBtReport (ConvertFrom-VivacBtPnpList $nodes))
    Assert-Equal 3 $lines.Count
    Assert-Equal 1 @($lines | ForEach-Object { $_.LastIndexOf((Join-Address '0011220000A1').Substring(0, 8)) } | Sort-Object -Unique).Count
}
# The report reads names and addresses only: no registry, no hive, no keys.
Case 'the Windows side never touches the registry' {
    foreach ($f in @('lib\BtSync.psm1', 'bin\vivac-bt-sync.ps1')) {
        $text = [IO.File]::ReadAllText((Join-Path $root $f))
        Assert-True ($text -notmatch '(?i)HKLM:|Registry::|reg\.exe|Set-ItemProperty|New-ItemProperty|BTHPORT') "registry access in $f"
    }
}
Complete-Cases
