# "Restart in Linux" (lib/BootNext.psm1, bin/vivac-reboot-other.ps1): the
# firmware list bcdedit prints, read in the languages it is printed in, and
# the Linux loader chosen from it. Nothing here touches the firmware.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\BootNext.psm1') -Force

$list = @(
    'Firmware Boot Manager', '---', 'identifier              {fwbootmgr}', 'displayorder            {bootmgr}', '',
    'Windows Boot Manager', '---', 'identifier              {bootmgr}', 'description             Windows Boot Manager', '',
    'Firmware Application (101fffff)', '---', 'identifier              {1c1a2b3c-0000-11ee-9a00-806e6f6e6963}', 'description             GRUB', '',
    'Firmware Application (101fffff)', '---', 'identifier              {2d2d2d2d-0000-11ee-9a00-806e6f6e6963}', 'description             UEFI OS'
)

Case 'every entry is read, with its identifier and description' {
    $entries = @(ConvertFrom-VivacFirmwareList $list)
    Assert-Equal 4 $entries.Count
    Assert-Equal 'GRUB' $entries[2].Description
}
Case 'the Linux loader is chosen, never the Windows one' {
    Assert-Equal '{1c1a2b3c-0000-11ee-9a00-806e6f6e6963}' (Select-VivacLinuxEntry (ConvertFrom-VivacFirmwareList $list)).Id
}
Case 'a Spanish list is read the same' {
    $es = $list -replace '^identifier', 'identificador' -replace '^description', ('descripci' + [char]0xF3 + 'n')
    Assert-Equal '{1c1a2b3c-0000-11ee-9a00-806e6f6e6963}' (Select-VivacLinuxEntry (ConvertFrom-VivacFirmwareList $es)).Id
}
Case 'a machine with Windows alone has no entry to restart into' {
    $only = @('Windows Boot Manager', '---', 'identifier              {bootmgr}', 'description             Windows Boot Manager')
    Assert-Equal $null (Select-VivacLinuxEntry (ConvertFrom-VivacFirmwareList $only))
}
Complete-Cases
