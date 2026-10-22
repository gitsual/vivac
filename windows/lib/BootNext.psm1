# The firmware's boot entries, as `bcdedit /enum firmware` lists them, read to
# find the Linux loader for "restart in Linux" (bin/vivac-reboot-other.ps1,
# docs/bridge.md at the product root). Kept apart from lib/Bridge.psm1: the
# elevated task that uses it copies only this file.

Set-StrictMode -Version 2.0

# The labels bcdedit uses for "description" in the languages Windows ships
# with most often; its output is translated, its identifiers are not.
$script:DescriptionKeys = @('description', ('descripci' + [char]0xF3 + 'n'), 'beschreibung', 'descrizione', ('descri' + [char]0xE7 + [char]0xE3 + 'o'))

# Entries of `bcdedit /enum firmware`: blocks separated by a blank line, each
# with an identifier ({guid} or {bootmgr}) and, usually, a description.
function ConvertFrom-VivacFirmwareList([string[]]$Lines) {
    $entries = @()
    $current = $null
    foreach ($line in @($Lines) + '') {
        if (-not $line.Trim()) {
            if ($current -and $current.Id) { $entries += [pscustomobject]$current }
            $current = $null
            continue
        }
        if ($line -match '^-+$') { continue }
        if ($line -notmatch '^(\S+)\s{2,}(.+?)\s*$') { continue }
        $key = $Matches[1].ToLowerInvariant(); $value = $Matches[2]
        if (-not $current) { $current = [ordered]@{ Id = $null; Description = '' } }
        if (-not $current.Id -and $value -match '^\{[^}]+\}$') { $current.Id = $value; continue }
        # By prefix too: a console code page can turn the accented label into
        # something else, never its first letters.
        if ($script:DescriptionKeys -contains $key -or $key -match '^(descri|beschr)') { $current.Description = $value }
    }
    $entries
}

# The entry "restart in Linux" boots: the first whose description names a
# Linux loader, never Windows' own boot manager or the firmware's.
function Select-VivacLinuxEntry($Entries, [string]$Pattern = 'GRUB|Arch|Linux|vivac|systemd-boot|rEFInd') {
    @($Entries | Where-Object {
            $_.Id -notmatch '^\{(fwbootmgr|bootmgr)\}$' -and
            $_.Description -notmatch 'Windows Boot Manager' -and
            $_.Description -match $Pattern
        }) | Select-Object -First 1
}

Export-ModuleMember -Function *
