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
    # ---- the sign-in script and its hook -----------------------------------
    $sync = Join-Path $root 'scripts\sync-shared-settings.ps1'
    $calls = Join-Path $dir 'calls.txt'
    foreach ($tool in 'apply', 'deploy') {
        Set-Content -LiteralPath (Join-Path $dir "$tool.ps1") -Value "Add-Content -LiteralPath '$calls' -Value (('$tool ' + (`$args -join ' ')).Trim())"
    }
    $env:VIVAC_APPLY_THEME = Join-Path $dir 'apply.ps1'
    $env:VIVAC_DEPLOY = Join-Path $dir 'deploy.ps1'
    function Invoke-Sync([string[]]$Arguments) {
        Remove-Item -LiteralPath $calls -Force -ErrorAction SilentlyContinue
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sync @Arguments 2>&1
        $script:SyncExit = $LASTEXITCODE
        $script:SyncOut = "$out"
        if (Test-Path -LiteralPath $calls) { (Get-Content -LiteralPath $calls) -join '|' } else { '' }
    }
    Case 'the script wants -Pull and nothing else' {
        Invoke-Sync @() | Out-Null
        Assert-Equal 2 $script:SyncExit
        Invoke-Sync @('-Pull', 'extra') | Out-Null
        Assert-Equal 2 $script:SyncExit
    }
    Case 'no sharing configured: silent, exit 0, nothing runs' {
        Reset-Pull '' $null
        Assert-Equal '' (Invoke-Sync @('-Pull'))
        Assert-Equal 0 $script:SyncExit
        Assert-Equal '' $script:SyncOut
    }
    Case 'a theme change re-applies the theme once; equal values run nothing' {
        Reset-Pull "shared_settings=$shared`ntheme=carmen`n" "theme=cosmos`n"
        Assert-Equal 'apply' (Invoke-Sync @('-Pull'))
        Assert-Equal 0 $script:SyncExit
        Assert-Equal 'cosmos' (Read-VivacSettings)['theme']
        Assert-Equal '' (Invoke-Sync @('-Pull'))
    }
    Case 'a location change redeploys the bar; a language change reloads nothing' {
        Write-Bytes $shared "theme=cosmos`nweather_location=40.42,-3.70`n"
        Assert-Equal 'deploy -Package zebar' (Invoke-Sync @('-Pull'))
        Write-Bytes $shared "language=en`n"
        Assert-Equal '' (Invoke-Sync @('-Pull'))
        Assert-Equal 'en' (Read-VivacSettings)['language']
    }
    Case 'a bad shared value does not fail the script' {
        Write-Bytes $shared "theme=nope`n"
        Assert-Equal '' (Invoke-Sync @('-Pull'))
        Assert-Equal 0 $script:SyncExit
        Assert-True ($script:SyncOut -match 'theme') 'the warning reaches the output'
    }
    Case 'an absent share is waited for, up to -WaitForShare, and never created' {
        $late = Join-Path $dir 'late'
        Set-LocalSettings "shared_settings=$late\settings`ntheme=carmen`n"
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Assert-Equal '' (Invoke-Sync @('-Pull', '-WaitForShare', '2'))
        Assert-Equal 0 $script:SyncExit
        Assert-True ($watch.Elapsed.TotalSeconds -ge 1.8) 'it did not wait'
        Assert-True (-not (Test-Path -LiteralPath $late)) 'the folder was created'
    }
    Case 'a share that shows up while waiting is pulled' {
        $late = Join-Path $dir 'late'
        $job = Start-Job -ArgumentList $late -ScriptBlock { param($d) Start-Sleep -Seconds 2; New-Item -ItemType Directory -Path $d | Out-Null; [IO.File]::WriteAllText("$d\settings", "theme=cosmos`n") }
        try { $r = Invoke-Sync @('-Pull', '-WaitForShare', '20') } finally { Wait-Job $job | Out-Null; Remove-Job $job }
        Assert-Equal 'apply' $r
        Assert-Equal 'cosmos' (Read-VivacSettings)['theme']
    }
    Case 'the host starts the pull only when sharing is configured' {
        Set-LocalSettings "theme=cosmos`n"
        Assert-True ($null -eq (Start-VivacSharedSync)) 'a process started with sharing off'
        $daemon = [IO.File]::ReadAllText((Join-Path $root 'bin\vivac-daemon.ps1'))
        Assert-True ($daemon -match 'Start-VivacSharedSync') 'the daemon does not start the pull'
    }
    # ---- a locked session is not disturbed ---------------------------------
    $marker = (Get-VivacPaths).LockMarker
    $deferred = (Get-VivacPaths).SharedDeferred
    Case 'the lock marker names its daemon and what kind of lock it is, and goes stale with it' {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        Assert-True ($null -eq (Get-VivacLockMarker)) 'a marker from nowhere'
        [void](Set-VivacLockMarker 'start')
        $m = Get-VivacLockMarker
        Assert-Equal $PID $m.Pid
        Assert-Equal 'start' $m.Kind
        Clear-VivacLockMarker
        Assert-True ($null -eq (Get-VivacLockMarker)) 'the marker was not cleared'
        [IO.File]::WriteAllText($marker, "2147483000 start`n")
        Assert-True ($null -eq (Get-VivacLockMarker)) 'a marker of a dead process counted'
        Remove-Item -LiteralPath $marker -Force
    }
    Case 'while the session is locked a theme from the pull is recorded, not applied; unlocking applies it once' {
        Reset-Pull "shared_settings=$shared`ntheme=carmen`n" "theme=cosmos`n"
        Remove-Item -LiteralPath $deferred -Force -ErrorAction SilentlyContinue
        [void](Set-VivacLockMarker 'start')
        try { Assert-Equal '' (Invoke-Sync @('-Pull')) } finally { Clear-VivacLockMarker }
        Assert-Equal 0 $script:SyncExit
        Assert-Equal 'cosmos' (Read-VivacSettings)['theme']
        Assert-Equal "theme`n" (Read-Bytes $deferred)
        Assert-Equal 'apply' (Invoke-Sync @('-Pull')) 'the deferred theme was not applied after the unlock'
        Assert-True (-not (Test-Path -LiteralPath $deferred)) 'the deferred list was not cleared'
        Assert-Equal '' (Invoke-Sync @('-Pull'))
    }
    Case 'a deferred location waits too; a language needs no reload and is never deferred' {
        Write-Bytes $shared "theme=cosmos`nweather_location=40.42,-3.70`nlanguage=en`n"
        [void](Set-VivacLockMarker 'lock')
        try { Assert-Equal '' (Invoke-Sync @('-Pull')) } finally { Clear-VivacLockMarker }
        Assert-Equal 'en' (Read-VivacSettings)['language']
        Assert-Equal "weather_location`n" (Read-Bytes $deferred)
        Assert-Equal 'deploy -Package zebar' (Invoke-Sync @('-Pull'))
    }
    Case 'the daemon is relaunched with -LockAtStart exactly when it had it' {
        Import-Module (Join-Path $root 'lib\Apps.psm1') -Force
        $with = @(Get-VivacDaemonLaunch 'C:\x\vivac-daemon.ps1' $true)
        $without = @(Get-VivacDaemonLaunch 'C:\x\vivac-daemon.ps1' $false)
        Assert-True ($with -contains '-LockAtStart') 'dropped'
        Assert-True ($without -notcontains '-LockAtStart') 'added'
        Assert-Equal ($without.Count + 1) $with.Count
        Assert-Equal '-File' $with[6]
        $apps = [IO.File]::ReadAllText((Join-Path $root 'lib\Apps.psm1'))
        Assert-True ($apps -match 'Get-VivacLockMarker' -and $apps -match 'Get-VivacDaemonLaunch \$script') 'Restart-VivacDaemon does not consult the lock marker'
    }
    Case 'the daemon marks its lock, clears it, and resumes a deferred pull' {
        $daemon = [IO.File]::ReadAllText((Join-Path $root 'bin\vivac-daemon.ps1'))
        Assert-True ($daemon -match "Set-VivacLockMarker 'start'") 'the start lock is not marked'
        Assert-True ($daemon -match 'Clear-VivacLockMarker') 'the marker is never cleared'
        Assert-True ($daemon -match 'Resume-SharedSync') 'a deferred pull is never resumed'
        $surf = [IO.File]::ReadAllText((Join-Path $root 'lib\Surfaces.psm1'))
        Assert-True ($surf -match "Invoke-VivacWithLockMarker 'lock'") 'a manual lock is not marked'
    }
    # ---- the marker must never get in the way of the lock ------------------
    function Use-UnwritableState([scriptblock]$Body) {
        # A file where the state directory should be: nothing can be created under it.
        $bad = Join-Path $dir 'unwritable'
        New-Item -ItemType Directory -Force -Path $bad | Out-Null
        [IO.File]::WriteAllText((Join-Path $bad 'vivac'), 'not a directory')
        $was = $env:VIVAC_LOCALAPPDATA
        $env:VIVAC_LOCALAPPDATA = $bad
        try { & $Body } finally { $env:VIVAC_LOCALAPPDATA = $was }
    }
    Case 'a marker that cannot be written, read or removed never throws' {
        Use-UnwritableState {
            Assert-True (-not (Set-VivacLockMarker 'start')) 'reported success'
            Assert-True ($null -eq (Get-VivacLockMarker)) 'read a marker from nowhere'
            Clear-VivacLockMarker
        }
    }
    Case 'the lock runs the same when the marker cannot be written, and a failing lock still lets go' {
        Use-UnwritableState {
            $ran = $false
            $r = Invoke-VivacWithLockMarker 'lock' { $script:ran = $true; 42 }
            Assert-True $script:ran 'the lock did not run'
            Assert-Equal 42 $r
            Assert-Throws { Invoke-VivacWithLockMarker 'lock' { throw 'the lock failed' } } 'the lock failed'
        }
    }
    Case 'with a writable state the marker is held during the lock and gone after, even when it fails' {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        $script:during = $null
        Invoke-VivacWithLockMarker 'lock' { $script:during = Get-VivacLockMarker }
        Assert-Equal 'lock' $script:during.Kind
        Assert-True ($null -eq (Get-VivacLockMarker)) 'the marker outlived the lock'
        Assert-Throws { Invoke-VivacWithLockMarker 'lock' { throw 'boom' } } 'boom'
        Assert-True ($null -eq (Get-VivacLockMarker)) 'the marker outlived a failed lock'
    }
    Case 'a lock inside the start-up cover leaves the cover marker alone' {
        [void](Set-VivacLockMarker 'start')
        try {
            Invoke-VivacWithLockMarker 'lock' { }
            Assert-Equal 'start' (Get-VivacLockMarker).Kind
        } finally { Clear-VivacLockMarker }
    }
    Case 'the daemon and the lock surface go through the guarded marker calls only' {
        $daemon = [IO.File]::ReadAllText((Join-Path $root 'bin\vivac-daemon.ps1'))
        $surf = [IO.File]::ReadAllText((Join-Path $root 'lib\Surfaces.psm1'))
        Assert-True ($surf -match "Invoke-VivacWithLockMarker 'lock'") 'Surfaces does not use the guarded wrapper'
        Assert-True ($surf -notmatch 'Set-VivacLockMarker|Clear-VivacLockMarker') 'Surfaces touches the marker directly'
        Assert-True ($daemon -notmatch 'LockMarker\s*[^\r\n]*Write-VivacFile') 'the daemon writes the marker by hand'
    }
    # ---- a stale marker must not outlive its session ------------------------
    function Get-CreationTicks([int]$Id) { (Get-CimInstance Win32_Process -Filter "ProcessId=$Id").CreationDate.ToFileTimeUtc() }
    Case 'a marker is live only for the very process that wrote it (a reused PID reads as stale)' {
        $other = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -WindowStyle Hidden -PassThru
        try {
            $ticks = Get-CreationTicks $other.Id
            [IO.File]::WriteAllText($marker, "$($other.Id) start $ticks`n")
            Assert-Equal $other.Id (Get-VivacLockMarker).Pid 'the real owner was not recognised'
            [IO.File]::WriteAllText($marker, "$($other.Id) start $($ticks - 36000000000)`n")
            Assert-True ($null -eq (Get-VivacLockMarker)) 'a live process with another start time counted'
            [IO.File]::WriteAllText($marker, "$($other.Id) start`n")
            Assert-True ($null -eq (Get-VivacLockMarker)) 'a marker without a start time counted'
            # Clearing a stale marker is allowed to anybody, even though its PID is not ours.
            [IO.File]::WriteAllText($marker, "$($other.Id) start $($ticks - 36000000000)`n")
            Clear-VivacLockMarker
            Assert-True (-not (Test-Path -LiteralPath $marker)) 'a stale marker was kept'
        } finally { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
    }
    Case 'our own marker round-trips with its start time' {
        [void](Set-VivacLockMarker 'start')
        try {
            Assert-True ([IO.File]::ReadAllText($marker) -match "^$PID start \d+\s*$") 'the marker has no start time'
            Assert-Equal $PID (Get-VivacLockMarker).Pid
        } finally { Clear-VivacLockMarker }
    }
    Case 'a host started without -LockAtStart drops whatever marker it finds, and never throws doing so' {
        $other = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -WindowStyle Hidden -PassThru
        try {
            [IO.File]::WriteAllText($marker, "$($other.Id) start $(Get-CreationTicks $other.Id)`n")
            Reset-VivacLockMarker
            Assert-True (-not (Test-Path -LiteralPath $marker)) 'the marker survived the start-up reset'
        } finally { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
        Use-UnwritableState { Reset-VivacLockMarker }
        $daemon = [IO.File]::ReadAllText((Join-Path $root 'bin\vivac-daemon.ps1'))
        Assert-True ($daemon -match '(?s)if \(\$LockAtStart\) \{[^}]*Set-VivacLockMarker[^}]*\} else \{ Reset-VivacLockMarker \}') 'the daemon does not reset the marker when started without -LockAtStart'
    }
    Case 'the Linux-strict shapes anchor at the very end (a trailing newline is not valid)' {
        Assert-True (-not (Test-VivacSharedValueValid 'language' "en`n")) 'language accepted a trailing newline'
        Assert-True (-not (Test-VivacSharedValueValid 'theme' "cosmos`n")) 'theme accepted a trailing newline'
        Assert-True (-not (Test-VivacSharedValueValid 'weather_location' "Lisbon`n")) 'location accepted a trailing newline'
    }
    Remove-Item Env:VIVAC_APPLY_THEME, Env:VIVAC_DEPLOY
    # ---- a failed replace never costs the shared file ----------------------
    $vivacModule = Get-Module Vivac
    function Set-ReplaceSeam([scriptblock]$Body) { & $vivacModule { param($b) $script:ReplaceFile = $b } $Body }
    function Reset-ReplaceSeam { & $vivacModule { $script:ReplaceFile = { param($s, $d, $b) [IO.File]::Replace($s, $d, $b) } } }
    function Get-Leftovers([string]$Folder) { @(Get-ChildItem -LiteralPath $Folder -Force | Where-Object { $_.Name -ne 'settings' }).Count }
    Case 'a replace that deletes the destination after making the backup restores the old file' {
        $f = Join-Path $dir 'replace\settings'
        Write-Bytes $f "theme=cosmos`nx=1`n"
        # What ReplaceFileW does on error 1177: the destination is moved to the backup and the scratch never lands.
        Set-ReplaceSeam { param($s, $d, $b) [IO.File]::Move($d, $b); throw (New-Object IO.IOException 'unable to move the replacement (1177)') }
        try { Assert-Throws { Write-VivacSharedKey $f 'theme' 'gatsby' } '1177' } finally { Reset-ReplaceSeam }
        Assert-Equal "theme=cosmos`nx=1`n" (Read-Bytes $f)
        Assert-Equal 0 (Get-Leftovers (Split-Path -Parent $f))
    }
    Case 'a replace that deletes the destination without a backup puts the new content there' {
        $f = Join-Path $dir 'replace\settings'
        Write-Bytes $f "theme=cosmos`nx=1`n"
        Set-ReplaceSeam { param($s, $d, $b) Remove-Item -LiteralPath $d -Force; throw (New-Object IO.IOException 'unable to move the replacement (1177)') }
        try { Assert-Throws { Write-VivacSharedKey $f 'theme' 'gatsby' } '1177' } finally { Reset-ReplaceSeam }
        Assert-True (Test-Path -LiteralPath $f) 'the shared file is gone'
        Assert-Equal "theme=gatsby`nx=1`n" (Read-Bytes $f)
        Assert-Equal 0 (Get-Leftovers (Split-Path -Parent $f))
    }
    Case 'a replace that fails and leaves the destination alone keeps it and cleans up' {
        $f = Join-Path $dir 'replace\settings'
        Write-Bytes $f "theme=cosmos`n"
        Set-ReplaceSeam { param($s, $d, $b) throw (New-Object IO.IOException 'sharing violation') }
        try { Assert-Throws { Write-VivacSharedKey $f 'theme' 'gatsby' } 'sharing' } finally { Reset-ReplaceSeam }
        Assert-Equal "theme=cosmos`n" (Read-Bytes $f)
        Assert-Equal 0 (Get-Leftovers (Split-Path -Parent $f))
    }
    Case 'a successful replace leaves no backup behind' {
        $f = Join-Path $dir 'replace\settings'
        Write-VivacSharedKey $f 'theme' 'carmen'
        Assert-Equal "theme=carmen`n" (Read-Bytes $f)
        Assert-Equal 0 (Get-Leftovers (Split-Path -Parent $f))
    }
    # ---- what reaches the shared file must be valid for Linux too ----------
    Case 'a shared key is stored lowercase, locally and in the shared file' {
        Set-LocalSettings "shared_settings=$shared`n"
        Write-Bytes $shared "x=1`n"
        Set-VivacSetting language EN
        Set-VivacSetting theme Bad-Romance
        Set-VivacSetting weather_location AUTO
        $s = Read-VivacSettings
        Assert-Equal 'en' $s['language']
        Assert-Equal 'bad-romance' $s['theme']
        Assert-Equal 'auto' $s['weather_location']
        Assert-Equal "x=1`nlanguage=en`ntheme=bad-romance`nweather_location=auto`n" (Read-Bytes $shared)
    }
    Case 'the Linux-strict shapes are case-sensitive' {
        Assert-True (Test-VivacSharedValueValid 'language' 'en') 'en'
        Assert-True (-not (Test-VivacSharedValueValid 'language' 'EN')) 'EN'
        Assert-True (Test-VivacSharedValueValid 'language' 'auto') 'auto'
        Assert-True (-not (Test-VivacSharedValueValid 'theme' 'Bad-Romance')) 'Bad-Romance'
        Assert-True (Test-VivacSharedValueValid 'theme' 'bad-romance') 'bad-romance'
        Assert-True (-not (Test-VivacSharedValueValid 'theme' '1abc')) '1abc'
        Assert-True (Test-VivacSharedValueValid 'weather_location' '40.42,-3.70') 'lat,lon'
        Assert-True (-not (Test-VivacSharedValueValid 'weather_location' 'a b')) 'space'
    }
    Case 'a value Linux would refuse stays local with a warning and never reaches the file or the queue' {
        Write-Bytes $shared "x=1`n"
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        $w = @(Send-VivacSharedKey 'language' 'EN' 3>&1)
        Assert-Equal 1 $w.Count
        Assert-True ("$($w[0])" -match 'language') 'the warning names the key'
        Assert-Equal "x=1`n" (Read-Bytes $shared)
        Assert-True (-not (Test-Path -LiteralPath $pending)) 'a refused value was queued'
    }
    # ---- the pull runs unseen: what goes wrong is logged -------------------
    $log = (Get-VivacPaths).SharedLog
    $pulls = (Get-VivacPaths).SharedPendingPulls
    function Clear-PullState { foreach ($f in $log, $pending, $pulls) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    Case 'a push that fails in the pull is logged with the key and the reason' {
        Clear-PullState
        $file = Join-Path $dir 'logshare\settings'
        Set-LocalSettings "shared_settings=$file`ntheme=carmen`n"
        Write-Bytes $file "theme=cosmos`n"
        [IO.File]::WriteAllText($pending, "theme`n")
        (Get-Item -LiteralPath $file).IsReadOnly = $true
        try { $null = @(Invoke-VivacSharedPull 3>&1) } finally { (Get-Item -LiteralPath $file).IsReadOnly = $false }
        Assert-True (Test-Path -LiteralPath $log) 'no log was written'
        $text = [IO.File]::ReadAllText($log)
        Assert-True ($text -match 'theme' -and $text -match 'could not send') "the log does not say what failed: $text"
    }
    Case 'a shared value the pull ignores is logged too' {
        Clear-PullState
        Set-LocalSettings "shared_settings=$shared`ntheme=carmen`n"
        Write-Bytes $shared "language=xx`n"
        $null = @(Invoke-VivacSharedPull 3>&1)
        $text = [IO.File]::ReadAllText($log)
        Assert-True ($text -match 'ignoring language' -and $text -match 'not valid') "missing: $text"
    }
    Case 'a key that stays pending across 3 pulls is warned about, then every pull; a push resets it' {
        Clear-PullState
        $file = Join-Path $dir 'never-there\settings'
        Set-LocalSettings "shared_settings=$file`ntheme=carmen`n"
        [IO.File]::WriteAllText($pending, "theme`n")
        foreach ($n in 1, 2) {
            $w = @(Invoke-VivacSharedPull 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            Assert-Equal 0 $w.Count "pull $n warned too early"
        }
        $w = @(Invoke-VivacSharedPull 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal 1 $w.Count 'pull 3 did not warn'
        Assert-True ("$($w[0])" -match 'theme' -and "$($w[0])" -match '3') 'the warning names the key and the count'
        Assert-True ([IO.File]::ReadAllText($log) -match 'theme.*3 pulls') 'the log has no record of it'
        $w = @(Invoke-VivacSharedPull 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal 1 $w.Count 'pull 4 stopped warning'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        $null = @(Invoke-VivacSharedPull 3>&1)
        Assert-Equal "theme=carmen`n" (Read-Bytes $file)
        Assert-True ((-not (Test-Path -LiteralPath $pulls)) -or ((Read-Bytes $pulls) -notmatch 'theme')) 'the count was not reset'
    }
} finally { Remove-TempProfile $dir }
Complete-Cases
