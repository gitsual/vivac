# Shared settings: three keys (theme, weather_location, language) can be
# mirrored to an optional flat key=value file another OS also reads. The write
# goes through on a local change; the read happens once at sign-in.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force
$root = Get-RepoRoot
$latin1 = [Text.Encoding]::GetEncoding(28591)

function Read-Bytes([string]$Path) { $latin1.GetString([IO.File]::ReadAllBytes($Path)) }
function Write-Bytes([string]$Path, [string]$Text) {
    $d = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllBytes($Path, $latin1.GetBytes($Text))
}
function Stamp([string]$Path) { $i = Get-Item -LiteralPath $Path; "$($i.LastWriteTimeUtc.Ticks) $($i.Length)" }
function Set-LocalSettings([string]$Text) {
    $p = (Get-VivacPaths).Settings
    Write-Bytes $p $Text
}

$dir = New-TempProfile
try {
    $shared = Join-Path $dir 'share\settings'
    $pending = Join-Path (Get-VivacPaths).State 'shared-pending'

    Case 'shared_settings is none by default and validates paths' {
        Assert-Equal 'none' (Read-VivacSettings)['shared_settings']
        foreach ($ok in 'none', 'C:\m2\vivac-shared\settings', 'C:/m2/vivac-shared/settings', '~\m2\settings', '~/m2/settings') {
            Set-VivacSetting shared_settings $ok
            Assert-Equal $ok (Read-VivacSettings)['shared_settings']
        }
        foreach ($bad in 'relative\path', 'C:', '~', '~x\y', 'C:\a|b', "C:\a`tb", '') {
            Assert-Throws { Set-VivacSetting shared_settings $bad } 'not a valid value'
        }
    }
    Case 'the shared path is none, absolute, or under the profile' {
        Set-LocalSettings "theme=cosmos`n"
        Assert-True ($null -eq (Get-VivacSharedPath)) 'unset means no sharing'
        Set-VivacSetting shared_settings 'none'
        Assert-True ($null -eq (Get-VivacSharedPath)) 'none means no sharing'
        Set-VivacSetting shared_settings $shared
        Assert-Equal $shared (Get-VivacSharedPath)
        Set-VivacSetting shared_settings '~/m2/shared/settings'
        Assert-Equal (Join-Path (Get-VivacPaths).Profile 'm2\shared\settings') (Get-VivacSharedPath)
        Set-VivacSetting shared_settings '~\m2\shared\settings'
        Assert-Equal (Join-Path (Get-VivacPaths).Profile 'm2\shared\settings') (Get-VivacSharedPath)
    }
    Case 'only theme, weather_location and language travel' {
        Assert-Equal 'theme,weather_location,language' ((Get-VivacSharedKeys) -join ',')
    }

    # ---- write-through ----------------------------------------------------
    Case 'a shared key is written through in place: foreign lines kept, LF only, no BOM' {
        Set-LocalSettings "shared_settings=$shared`n"
        Write-Bytes $shared "$([char]0xEF)$([char]0xBB)$([char]0xBF)mod=lwin`r`ntheme=carmen`r`nzzz=1`r`n"
        Set-VivacSetting theme cosmos
        Assert-Equal "mod=lwin`ntheme=cosmos`nzzz=1`n" (Read-Bytes $shared)
        Set-VivacSetting language en
        Assert-Equal "mod=lwin`ntheme=cosmos`nzzz=1`nlanguage=en`n" (Read-Bytes $shared)
        Assert-Equal 'cosmos' (Read-VivacSettings)['theme']
    }
    Case 'an unchanged value does not rewrite the shared file' {
        (Get-Item -LiteralPath $shared).LastWriteTimeUtc = [datetime]'2020-01-01'
        $before = Stamp $shared
        Set-VivacSetting theme cosmos
        Assert-Equal $before (Stamp $shared)
    }
    Case 'duplicates collapse onto the first line and a missing final newline is tolerated' {
        Write-Bytes $shared "theme=a`nx=1`ntheme=b"
        Set-VivacSetting theme gatsby
        Assert-Equal "theme=gatsby`nx=1`n" (Read-Bytes $shared)
    }
    Case 'local-only keys never reach the shared file' {
        Write-Bytes $shared "x=1`n"
        Set-VivacSetting mod alt
        Set-VivacSetting shared_settings $shared
        Assert-Equal "x=1`n" (Read-Bytes $shared)
    }
    Case 'no sharing configured writes nothing anywhere' {
        Set-LocalSettings "theme=carmen`n"
        Remove-Item -LiteralPath $shared -Force
        Set-VivacSetting theme cosmos
        Assert-True (-not (Test-Path -LiteralPath $shared)) 'the shared file appeared'
        Assert-True (-not (Test-Path -LiteralPath $pending)) 'a pending list appeared'
    }
    Case 'an absent shared folder keeps the change local, queues it, and warns once' {
        $gone = Join-Path $dir 'offline\settings'
        Set-LocalSettings "shared_settings=$gone`ntheme=carmen`n"
        $out = @(Set-VivacSetting theme cosmos 3>&1)
        Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $gone))) 'the missing folder was created'
        Assert-Equal 'cosmos' (Read-VivacSettings)['theme']
        Assert-Equal "theme`n" (Read-Bytes $pending)
        Assert-Equal 1 $out.Count
        Assert-True ("$($out[0])" -match 'theme') 'the warning names the key'
        $out = @(Set-VivacSetting theme gatsby 3>&1)
        Assert-Equal 0 $out.Count 'the same key warned twice'
        Assert-Equal "theme`n" (Read-Bytes $pending)
        Set-VivacSetting language en 3>&1 | Out-Null
        Assert-Equal "theme`nlanguage`n" (Read-Bytes $pending)
    }
    Case 'an invalid value is refused before anything is queued or written' {
        Remove-Item -LiteralPath $pending -Force
        Assert-Throws { Set-VivacSetting theme 'no such theme' } 'no theme'
        Assert-True (-not (Test-Path -LiteralPath $pending)) 'a refused value was queued'
    }
    Case 'a busy lock defers the shared write and never loses the local one' {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $shared) | Out-Null
        Write-Bytes $shared "theme=cosmos`n"
        Set-LocalSettings "shared_settings=$shared`ntheme=cosmos`n"
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        $lockPath = Join-Path (Get-VivacPaths).State 'shared-sync.lock'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
        $held = New-Object IO.FileStream($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        $env:VIVAC_SETTINGS_LOCK_WAIT = '1'
        try {
            $w = @(Set-VivacSetting theme gatsby 3>&1)
        } finally { $held.Dispose(); Remove-Item Env:VIVAC_SETTINGS_LOCK_WAIT }
        Assert-Equal 'gatsby' (Read-VivacSettings)['theme']
        Assert-Equal "theme=cosmos`n" (Read-Bytes $shared)
        Assert-Equal "theme`n" (Read-Bytes $pending)
        Assert-Equal 1 $w.Count
    }
    Case 'a successful write-through clears the key from the pending list' {
        Set-VivacSetting theme carmen
        Assert-Equal "theme=carmen`n" (Read-Bytes $shared)
        Assert-True ((Read-Bytes $pending) -notmatch 'theme') 'theme is still pending'
    }
} finally { Remove-TempProfile $dir }
Complete-Cases
