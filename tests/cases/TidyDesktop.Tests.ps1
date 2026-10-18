# The desktop tidier: shortcuts leave the desktop, every one stays reachable
# from the Start menu, and nothing that is not a shortcut moves.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
$tidy = Join-Path $root 'bin\vivac-tidy-desktop.ps1'

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments = '') {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $s.TargetPath = $Target
    $s.Arguments = $Arguments
    $s.Save()
}

$dir = New-TempProfile
try {
    $desk = Join-Path $dir 'desktop'
    $start = Join-Path $dir 'start'
    $backup = Join-Path $dir 'backup'
    New-Item -ItemType Directory -Force -Path $desk, (Join-Path $start 'Vendor') | Out-Null
    $exe = Join-Path $env:WINDIR 'System32\notepad.exe'
    New-Shortcut (Join-Path $start 'Vendor\Notepad.lnk') $exe
    New-Shortcut (Join-Path $desk 'Notepad.lnk') $exe
    New-Shortcut (Join-Path $desk 'Notepad file.lnk') $exe 'C:\notes.txt'
    Set-Content -LiteralPath (Join-Path $desk 'Game.url') -Value "[InternetShortcut]`r`nURL=steam://rungameid/480"
    Set-Content -LiteralPath (Join-Path $desk 'notes.txt') -Value 'mine'
    New-Item -ItemType Directory -Path (Join-Path $desk 'folder') | Out-Null
    $common = @{ Desktops = @($desk); StartMenus = @($start); Backup = $backup }

    Case 'a dry run moves nothing' {
        $out = @(& $tidy @common -DryRun)
        Assert-Equal 3 $out.Count 'one line per shortcut'
        Assert-Equal 3 @(Get-ChildItem -LiteralPath $desk -File | Where-Object Extension -in '.lnk', '.url').Count
    }

    [void](& $tidy @common)

    Case 'no shortcut is left on the desktop, and nothing else moves' {
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $desk -File | Where-Object Extension -in '.lnk', '.url').Count
        Assert-True (Test-Path -LiteralPath (Join-Path $desk 'notes.txt')) 'a file stays'
        Assert-True (Test-Path -LiteralPath (Join-Path $desk 'folder')) 'a folder stays'
    }
    Case 'one the Start menu already reaches goes to the backup' {
        Assert-True (Test-Path -LiteralPath (Join-Path $backup "$(Get-Date -Format 'yyyyMMdd')\Notepad.lnk"))
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $start 'Notepad.lnk'))) 'not added twice'
    }
    Case 'one it does not reach becomes a Start menu entry, arguments and URLs included' {
        Assert-True (Test-Path -LiteralPath (Join-Path $start 'Notepad file.lnk')) 'same program, other arguments'
        Assert-True (Test-Path -LiteralPath (Join-Path $start 'Game.url'))
    }
    Case 'a second pass finds nothing to do' {
        Assert-Equal 0 @(& $tidy @common).Count
    }
    Case 'registering is described, not done, in a dry run' {
        Assert-True ((& $tidy @common -Register -DryRun) -match '\\vivac\\tidy-desktop.*-Watch')
    }
} finally {
    Remove-TempProfile $dir
}
Complete-Cases
