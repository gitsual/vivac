# The deployment regression, in a scratch profile: a dry run writes nothing,
# a second pass changes nothing, a file that is not vivac's is backed up before
# it is replaced, a file edited after a deploy is never silently lost, and an
# uninstall puts back exactly what was there.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
$deploy = Join-Path $root 'scripts\deploy.ps1'
$uninstall = Join-Path $root 'scripts\uninstall.ps1'
$files = 'glazewm', 'zebar', 'flow', 'terminal', 'nvim'

function Get-Tree([string]$Dir) {
    @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | ForEach-Object {
            $_.FullName.Substring($Dir.Length) + ' ' + (Get-FileHash -LiteralPath $_.FullName).Hash
        } | Sort-Object)
}

# A Windows Terminal settings file with a comment, a trailing comma and a
# setting of the user's own, as a real one may have.
$wtJson = @'
{
    // the user's own comment
    "defaultProfile": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}",
    "copyOnSelect": true,
    "profiles": { "defaults": { "fontSize": 13 }, "list": [ { "name": "PowerShell", "hidden": false }, ] },
    "schemes": [ { "name": "Campbell", "background": "#0C0C0C" } ]
}
'@

$dir = New-TempProfile
try {
    $wt = Join-Path $env:VIVAC_LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $wt) | Out-Null
    [IO.File]::WriteAllText($wt, $wtJson)
    $flow = Join-Path $env:VIVAC_APPDATA 'FlowLauncher\Settings\Settings.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $flow) | Out-Null
    [IO.File]::WriteAllText($flow, '{"Theme":"Win11Light","Hotkey":"Alt + R","QueryBoxFontSize":18}')
    # A GlazeWM config the user already had.
    $glaze = Join-Path $env:VIVAC_PROFILE '.glzr\glazewm\config.yaml'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $glaze) | Out-Null
    [IO.File]::WriteAllText($glaze, "# mine`n")
    # Facts from a fixture, so the result does not depend on this machine.
    New-Item -ItemType Directory -Force -Path (Join-Path $env:VIVAC_APPDATA 'vivac') | Out-Null
    Copy-Item (Join-Path $root 'tests\golden\laptop-intel\hardware-facts') (Join-Path $env:VIVAC_APPDATA 'vivac\hardware-facts')
    $before = Get-Tree $dir

    Case 'a dry run writes nothing at all' {
        & $deploy -DryRun -Package $files *> $null
        Assert-Equal $before (Get-Tree $dir) 'tree changed under -DryRun'
    }
    Case 'the first pass writes every file and backs up the ones it replaces' {
        & $deploy -Package $files -NoReload *> $null
        Assert-True (Test-Path (Join-Path $env:VIVAC_PROFILE '.glzr\zebar\vivac\zpack.json'))
        Assert-True (Test-Path (Join-Path $env:VIVAC_LOCALAPPDATA 'nvim\lua\themes\vivac.lua'))
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $env:VIVAC_LOCALAPPDATA 'vivac\backups') -Recurse -File)
        Assert-Equal 3 $backups.Count 'backups (glazewm, terminal, flow)'
        $mine = $backups | Where-Object { $_.Name -eq 'config.yaml' }
        Assert-Equal "# mine`n" ([IO.File]::ReadAllText($mine.FullName)) 'the backup is the original'
    }
    Case 'the terminal keeps the user settings and gains the scheme' {
        $s = [IO.File]::ReadAllText($wt) | ConvertFrom-Json
        Assert-Equal 'vivac' $s.profiles.defaults.colorScheme
        Assert-Equal 13 $s.profiles.defaults.fontSize 'a default of the user'
        Assert-Equal $true $s.copyOnSelect
        Assert-Equal 'Campbell,vivac' (@($s.schemes | ForEach-Object { $_.name }) -join ',')
    }
    Case 'the launcher keeps its settings and gains the theme and hotkey' {
        $s = [IO.File]::ReadAllText($flow) | ConvertFrom-Json
        Assert-Equal 'vivac' $s.Theme
        Assert-Equal 'Alt + Space' $s.Hotkey
        Assert-Equal 18 $s.QueryBoxFontSize
    }
    Case 'the second pass changes nothing' {
        $first = Get-Tree $dir
        & $deploy -Package $files -NoReload *> $null
        Assert-Equal $first (Get-Tree $dir) 'second pass changed files'
    }
    Case 'a deployed file edited by the user is backed up before the next deploy' {
        [IO.File]::AppendAllText($glaze, "# edited`n")
        $n = @(Get-ChildItem -LiteralPath (Join-Path $env:VIVAC_LOCALAPPDATA 'vivac\backups') -Recurse -File).Count
        & $deploy -Package glazewm -NoReload *> $null
        $after = @(Get-ChildItem -LiteralPath (Join-Path $env:VIVAC_LOCALAPPDATA 'vivac\backups') -Recurse -File)
        Assert-Equal ($n + 1) $after.Count
        Assert-True ([IO.File]::ReadAllText($glaze) -notmatch '# edited') 'the edit was replaced'
        Assert-True (@($after | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '# edited' }).Count -eq 1) 'and kept in a backup'
    }
    Case 'the manifest holds and the integrity check agrees' {
        Import-Module (Join-Path $root 'lib\Deploy.psm1') -Force
        Assert-Equal 0 @(Test-VivacDeployIntegrity).Count
        [IO.File]::AppendAllText((Join-Path $env:VIVAC_PROFILE '.glzr\zebar\vivac\bar.js'), '//x')
        Assert-Equal 1 @(Test-VivacDeployIntegrity).Count
    }
    Case 'switching the theme rewrites only what carries a colour' {
        Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
        & $deploy -Package $files -NoReload *> $null
        $out = & $deploy -Package $files -NoReload -Theme cosmos 6>&1 | Out-String
        foreach ($f in 'config.yaml', 'styles.css', 'vivac.xaml', 'settings.json', 'vivac.lua') { Assert-True ($out -match [regex]::Escape($f)) "$f was not rewritten" }
        foreach ($f in 'bar.js', 'zpack.json', 'init.lua') { Assert-True ($out -notmatch "\\$([regex]::Escape($f))") "$f has no colour and should not change" }
        Assert-True ([IO.File]::ReadAllText($glaze) -match "#e8c66a") 'border in the cosmos accent'
    }
    Case 'uninstall restores the originals and removes the rest' {
        & $uninstall *> $null
        Assert-Equal "# mine`n" ([IO.File]::ReadAllText($glaze)) 'the GlazeWM config the user had'
        Assert-True ([IO.File]::ReadAllText($wt) -match "the user's own comment") 'the terminal settings, comments included'
        Assert-True (-not (Test-Path (Join-Path $env:VIVAC_PROFILE '.glzr\zebar\vivac\index.html'))) 'files vivac created are gone'
    }
} finally {
    Remove-TempProfile $dir
}
Complete-Cases
