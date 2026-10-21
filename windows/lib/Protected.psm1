# Where what runs elevated lives.
#
# A task that runs elevated without a prompt must not run a file the user can
# write without one: any program running as the user could edit it and then
# have it run as administrator, which is UAC undone. So what an elevated task
# runs is copied, by an elevated script, into C:\Program Files\vivac, which
# only administrators can write (it inherits Program Files' permissions), and
# the task points there. The repository stays the source; scripts/protect-
# tasks.ps1 copies it again after an update (one UAC prompt per update).
#
# Elevated tasks also write logs and, for winget, read requests. Those live in
# C:\ProgramData\vivac, made here with permissions of its own: administrators
# and SYSTEM write, the user only reads -- but for the winget inbox, where the
# user may drop request files and nothing else (no deleting or renaming the
# folder, so it cannot be swapped for a link that sends the task elsewhere).

Set-StrictMode -Version 2.0

$script:ProgramRoot = Join-Path $env:ProgramFiles 'vivac'
$script:DataRoot = Join-Path $env:ProgramData 'vivac'

function Get-VivacProtectedPaths {
    @{
        Program = $script:ProgramRoot
        Data    = $script:DataRoot
        Logs    = Join-Path $script:DataRoot 'logs'
        Inbox   = Join-Path $script:DataRoot 'winget\inbox'
        Outbox  = Join-Path $script:DataRoot 'winget\out'
    }
}

function Test-VivacElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# A path is safe for an elevated task to follow when no part of it is a link.
function Test-VivacNoReparse([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            if (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $parent = [IO.Path]::GetDirectoryName($p)
        if ($parent -eq $p) { break }
        $p = $parent
    }
    $true
}

# Copies files of the repository, by their paths relative to it, under
# C:\Program Files\vivac\<Into>, keeping their layout (a script that loads
# lib\x.psm1 from its parent folder finds it there too). Returns that folder.
function Install-VivacProtectedFiles([string]$RepoRoot, [string[]]$Files, [string]$Into) {
    if (-not (Test-VivacElevated)) { throw 'Install-VivacProtectedFiles: needs an elevated PowerShell' }
    $dest = Join-Path $script:ProgramRoot $Into
    if (-not (Test-Path -LiteralPath $script:ProgramRoot)) { New-Item -ItemType Directory -Path $script:ProgramRoot | Out-Null }
    if (-not (Test-VivacNoReparse $dest)) { throw "Install-VivacProtectedFiles: $dest goes through a link" }
    foreach ($rel in $Files) {
        $src = Join-Path $RepoRoot $rel
        $to = Join-Path $dest $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        Copy-Item -LiteralPath $src -Destination $to -Force
    }
    $dest
}

# Files of the repository whose protected copy differs from it (or is
# missing): what scripts/protect-tasks.ps1 would copy again.
function Get-VivacProtectedDrift([string]$RepoRoot, [string[]]$Files, [string]$Into) {
    $dest = Join-Path $script:ProgramRoot $Into
    foreach ($rel in $Files) {
        $a = Join-Path $RepoRoot $rel
        $b = Join-Path $dest $rel
        if (-not (Test-Path -LiteralPath $b) -or (Get-FileHash -LiteralPath $a).Hash -ne (Get-FileHash -LiteralPath $b).Hash) { $rel }
    }
}

# C:\ProgramData\vivac and its folders, with permissions set here rather than
# inherited: ProgramData lets every user create folders, which is exactly
# what must not reach these.
function Initialize-VivacDataRoot([string]$User) {
    if (-not (Test-VivacElevated)) { throw 'Initialize-VivacDataRoot: needs an elevated PowerShell' }
    $p = Get-VivacProtectedPaths
    foreach ($d in $p.Data, $p.Logs, (Split-Path -Parent $p.Inbox), $p.Inbox, $p.Outbox) {
        if (-not (Test-VivacNoReparse $d)) { throw "Initialize-VivacDataRoot: $d goes through a link" }
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
    # C:\ProgramData\vivac itself is the user's to write on purpose (the lock
    # screen picture and the boot stage, lib/Desktop.psm1 and lib/Boot.psm1),
    # so it is left alone: only logs and winget get permissions of their own,
    # not inherited from it, administrators and SYSTEM owning them and users
    # reading. Without delete rights on them the user cannot rename or swap
    # them either, whatever they may do in the folder around them.
    #
    # The permissions are set on the folder alone, and what is inside is
    # then reset to inherit them. Not icacls /T with the grants: that strips
    # inheritance from every file too, and (OI)(CI) grants mean nothing on a
    # file, so files already there were left with no entry at all -- refused
    # even to administrators. takeown first, so files left that way by an
    # earlier run can be reset again.
    foreach ($d in $p.Logs, (Split-Path -Parent $p.Inbox)) {
        & takeown.exe /F $d /A /R | Out-Null
        & icacls.exe $d /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q | Out-Null
        if (Get-ChildItem -LiteralPath $d -Force) { & icacls.exe (Join-Path $d '*') /reset /T /C /Q | Out-Null }
    }
    # The inbox: the user may add files there (and change the ones they
    # added), not delete or rename the folder itself.
    & icacls.exe $p.Inbox /grant "${User}:(WD,RX)" '*S-1-3-0:(OI)(IO)M' /C /Q | Out-Null
}

Export-ModuleMember -Function Get-VivacProtectedPaths, Test-VivacElevated, Test-VivacNoReparse, Install-VivacProtectedFiles, Get-VivacProtectedDrift, Initialize-VivacDataRoot
