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
    # ---- pull -------------------------------------------------------------
    function Reset-Pull([string]$Local, $SharedText) {
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        Set-LocalSettings $Local
        if ($null -ne $SharedText) { Write-Bytes $shared $SharedText }
        elseif (Test-Path -LiteralPath $shared) { Remove-Item -LiteralPath $shared -Force }
    }
    Case 'a pull with no sharing, no settings, or no shared file is silent and creates nothing' {
        Reset-Pull '' $null
        Assert-Equal 0 @(Invoke-VivacSharedPull 3>&1).Count
        Set-LocalSettings "shared_settings=$shared`n"
        Assert-Equal 0 @(Invoke-VivacSharedPull 3>&1).Count
        Assert-True (-not (Test-Path -LiteralPath $shared)) 'the pull created the shared file'
        Set-LocalSettings "shared_settings=$(Join-Path $dir 'nowhere\settings')`n"
        Assert-Equal 0 @(Invoke-VivacSharedPull 3>&1).Count
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dir 'nowhere'))) 'the pull created the folder'
    }
    Case 'the other OS changed the theme: applied, foreign and local keys untouched, shared file not written' {
        Reset-Pull "shared_settings=$shared`ntheme=carmen`nmod=alt`n" "mod=lwin`r`ntheme=cosmos`r`nkeymap=us`r`n"
        (Get-Item -LiteralPath $shared).LastWriteTimeUtc = [datetime]'2020-01-01'
        $before = Stamp $shared
        $r = @(Invoke-VivacSharedPull 3>&1)
        Assert-Equal 'theme' ($r -join ',')
        $s = Read-VivacSettings
        Assert-Equal 'cosmos' $s['theme']
        Assert-Equal 'alt' $s['mod']
        Assert-Equal $before (Stamp $shared)
    }
    Case 'equal values change nothing' {
        $p = (Get-VivacPaths).Settings
        (Get-Item -LiteralPath $p).LastWriteTimeUtc = [datetime]'2020-01-01'
        $before = Stamp $p
        Assert-Equal 0 @(Invoke-VivacSharedPull 3>&1).Count
        Assert-Equal $before (Stamp $p)
    }
    Case 'a BOM, CR and a missing final newline are read; the last of a repeated key wins' {
        Reset-Pull "shared_settings=$shared`n" "$([char]0xEF)$([char]0xBB)$([char]0xBF)language=es`r`nlanguage=en`r`nweather_location=40.42,-3.70"
        $r = @(Invoke-VivacSharedPull 3>&1)
        Assert-Equal 'weather_location,language' ($r -join ',')
        Assert-Equal 'en' (Read-VivacSettings)['language']
        Assert-Equal '40.42,-3.70' (Read-VivacSettings)['weather_location']
    }
    Case 'an invalid shared value is reported and skipped, the others still land' {
        Reset-Pull "shared_settings=$shared`ntheme=carmen`n" "theme=not-a-theme`nlanguage=xx`nweather_location=40.42,-3.70`n"
        $out = @(Invoke-VivacSharedPull 3>&1)
        $warnings = @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal 2 $warnings.Count
        Assert-True (("$($warnings -join ' ')") -match 'theme' -and ("$($warnings -join ' ')") -match 'language') 'warnings name the keys'
        $s = Read-VivacSettings
        Assert-Equal 'carmen' $s['theme']
        Assert-Equal '40.42,-3.70' $s['weather_location']
    }
    Case 'a garbled file does not crash the pull or change anything' {
        Reset-Pull "shared_settings=$shared`ntheme=carmen`n" "$([char]0)$([char]0xFF)$([char]1)garbage`nno-equals`ntheme=$([char]1)`n=x`n"
        $p = (Get-VivacPaths).Settings
        (Get-Item -LiteralPath $p).LastWriteTimeUtc = [datetime]'2020-01-01'
        $before = Stamp $p
        $null = @(Invoke-VivacSharedPull 3>&1)
        Assert-Equal $before (Stamp $p)
    }
    Case 'a change made while the share was away goes out first and the local value wins' {
        $offline = Join-Path $dir 'offline-share'
        $file = Join-Path $offline 'settings'
        Set-LocalSettings "shared_settings=$file`ntheme=carmen`n"
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        Set-VivacSetting theme gatsby 3>&1 | Out-Null
        Set-VivacSetting language en 3>&1 | Out-Null
        Assert-Equal "theme`nlanguage`n" (Read-Bytes $pending)
        Write-Bytes $file "mod=lwin`ntheme=carmen`nlanguage=es`n"
        $r = @(Invoke-VivacSharedPull 3>&1)
        Assert-Equal 0 $r.Count 'pending keys are not reported as taken from the share'
        Assert-Equal 'gatsby' (Read-VivacSettings)['theme']
        Assert-Equal "mod=lwin`ntheme=gatsby`nlanguage=en`n" (Read-Bytes $file)
        Assert-Equal '' (Read-Bytes $pending)
        # Pending cleared: the other OS wins again.
        Write-Bytes $file "theme=cosmos`n"
        Assert-Equal 'theme' (@(Invoke-VivacSharedPull 3>&1) -join ',')
        Assert-Equal 'cosmos' (Read-VivacSettings)['theme']
    }
    Case 'a pending key whose push fails keeps its local value and stays pending' {
        $file = Join-Path $dir 'offline-share\settings'
        Set-LocalSettings "shared_settings=$file`ntheme=carmen`n"
        Write-Bytes $file "theme=cosmos`n"
        [IO.File]::WriteAllText($pending, "theme`n")
        (Get-Item -LiteralPath $file).IsReadOnly = $true
        try { $null = @(Invoke-VivacSharedPull 3>&1) } finally { (Get-Item -LiteralPath $file).IsReadOnly = $false }
        Assert-Equal 'carmen' (Read-VivacSettings)['theme']
        Assert-Equal "theme`n" (Read-Bytes $pending)
        Assert-Equal "theme=cosmos`n" (Read-Bytes $file)
        $null = @(Invoke-VivacSharedPull 3>&1)
        Assert-Equal "theme=carmen`n" (Read-Bytes $file)
        Assert-Equal '' (Read-Bytes $pending)
    }
    Case 'a pending key with the share absent stays pending' {
        $file = Join-Path $dir 'still-away\settings'
        Set-LocalSettings "shared_settings=$file`ntheme=carmen`n"
        [IO.File]::WriteAllText($pending, "theme`n")
        Assert-Equal 0 @(Invoke-VivacSharedPull 3>&1).Count
        Assert-Equal "theme`n" (Read-Bytes $pending)
        Assert-True (-not (Test-Path -LiteralPath (Split-Path -Parent $file))) 'the folder was created'
    }
    Case 'a pending key creates the shared file when only the folder is there' {
        $folder = Join-Path $dir 'fresh'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Set-LocalSettings "shared_settings=$folder\settings`ntheme=cosmos`n"
        [IO.File]::WriteAllText($pending, "theme`n")
        $null = @(Invoke-VivacSharedPull 3>&1)
        Assert-Equal "theme=cosmos`n" (Read-Bytes "$folder\settings")
    }
    Case 'a pull that cannot get the lock gives up quietly and changes nothing' {
        Reset-Pull "shared_settings=$shared`ntheme=carmen`n" "theme=cosmos`n"
        $lockPath = (Get-VivacPaths).SharedLock
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
        $held = New-Object IO.FileStream($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try { $out = @(Invoke-VivacSharedPull -LockWaitSeconds 1 3>&1) } finally { $held.Dispose() }
        Assert-Equal 0 $out.Count
        Assert-Equal 'carmen' (Read-VivacSettings)['theme']
    }
} finally { Remove-TempProfile $dir }
Complete-Cases
