# The sign-in greeter (bin\vivac-greeter.ps1, lib\Greeter.psm1): alone on a
# desktop of its own, the password the one way in, and never a screen left
# on an empty desktop. The desktop switch itself is only tried for real with
# `bin\vivac-greeter.ps1 -Preview 5`: a gate must not take the screen.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$dir = New-TempProfile
try {
    Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
    Import-Module (Join-Path $root 'lib\Switch.psm1') -Force
    Import-Module (Join-Path $root 'lib\Greeter.psm1') -Force
    $greeter = Join-Path $root 'bin\vivac-greeter.ps1'
    $state = (Get-VivacPaths).State
    $log = Join-Path $state 'lock.log'
    $locks = Join-Path $dir 'locks.txt'
    $fakeLock = Join-Path $dir 'fake-lock.cmd'
    Set-Content -LiteralPath $fakeLock -Value "@echo locked>>`"$locks`"" -Encoding ASCII
    function Invoke-Greeter {
        $env:VIVAC_GREETER_LOCK = $fakeLock
        try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $greeter | Out-Null } finally { Remove-Item Env:VIVAC_GREETER_LOCK -ErrorAction SilentlyContinue }
    }

    Case 'the gate runs on the programs'' desktop, and the native names it' {
        $n = Get-VivacDesktopNative
        Assert-Equal 'Default' $n::InputDesktopName() 'the input desktop'
        Assert-Equal 'Default' $n::ThreadDesktopName() 'this thread''s desktop'
    }
    Case 'a desktop of its own is made, and a fresh thread binds to it; the first thread cannot' {
        $n = Get-VivacDesktopNative
        $h = $n::Create('vivac-greeter-gate')
        try {
            Assert-True ($h -ne [IntPtr]::Zero) 'no desktop'
            # This thread already owns windows (ERROR_BUSY): why the greeter builds on a runspace of its own.
            Assert-Throws { $n::Bind($h) } 'SetThreadDesktop'
            $rs = [RunspaceFactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'UseNewThread'; $rs.Open()
            $ps = [PowerShell]::Create(); $ps.Runspace = $rs
            [void]$ps.AddScript({ param($H) [VivacDesktopNative]::Bind($H); [VivacDesktopNative]::ThreadDesktopName() }).AddArgument($h)
            $name = [string]($ps.Invoke() | Select-Object -First 1)
            $ps.Dispose(); $rs.Close()
            Assert-Equal 'vivac-greeter-gate' $name 'the runspace thread is not on the new desktop'
            Assert-Equal 'Default' $n::InputDesktopName() 'binding a thread switches nothing on screen'
        } finally { $n::Close($h) }
    }
    Case 'the lock knows which desktop has the keyboard' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $native = Get-LockNative
        Assert-Equal 'Default' $native::InputDesktopName()
        Assert-True $native::OnDesktop('Default')
        Assert-True $native::OnUserDesktop()
        Assert-True (-not $native::OnDesktop((Get-VivacGreeterDesktopName))) 'the greeter''s desktop is not up'
    }
    Case 'the sign-in greeter asks first what the session''s lock asks, offers the other by Tab, and leaves the lock mode alone' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        Set-VivacLockMode pin
        $pinFirst = Show-VivacLock -NoShow -Greeter -FirstMode pin -Desktop (Get-VivacGreeterDesktopName)
        Assert-Equal 'Collapsed' ([string]$pinFirst.FindName('Secret').Visibility) 'the PIN first still shows the password field'
        Assert-Equal (Get-VivacString 'lock.pin_placeholder') ([string]$pinFirst.FindName('Placeholder').Text) 'the PIN first does not say so'
        $pinFirst.Close()
        $w = Show-VivacLock -NoShow -Greeter -FirstMode password -Desktop (Get-VivacGreeterDesktopName)
        Assert-Equal 'Visible' ([string]$w.FindName('Secret').Visibility) 'the field takes the password'
        Assert-Equal 'Visible' ([string]$w.FindName('ModeSwitch').Visibility) 'no way to the PIN'
        Assert-Equal (Get-VivacString 'lock.account_placeholder') ([string]$w.FindName('Placeholder').Text) 'the field does not say it wants the account''s password'
        $w.Close()
        Assert-Equal 'pin' (Get-VivacLockMode) 'the session''s own lock keeps its way in'
        $only = Show-VivacLock -NoShow -Greeter -PasswordOnly -Desktop (Get-VivacGreeterDesktopName)
        Assert-Equal 'Collapsed' ([string]$only.FindName('ModeSwitch').Visibility) 'password-only still offers the PIN'
        $only.Close()
        $text = Get-Content -Raw -LiteralPath (Join-Path $root 'lib\Surfaces.psm1')
        Assert-True ($text -match '\$keepMode = \$PasswordOnly -or \[bool\]\$FirstMode') 'the greeter writes the session''s lock mode'
        Assert-True ($text -notmatch '(?m)^\s+Set-VivacLockMode \$state\.Mode\s*$') 'a toggle writes the lock mode unguarded'
        # Hello from a desktop of its own: the screen to Default for the prompt (the stage told first), back if not verified.
        $helloAt = $text.IndexOf('$hello = {')
        $onHello = $text.IndexOf('& $OnHello $true', $helloAt); $toDefault = $text.IndexOf('$native::SwitchToDefault()', $helloAt); $ask = $text.IndexOf('Start-HelloVerification', $helloAt)
        Assert-True ($helloAt -gt 0 -and $onHello -gt $helloAt -and $toDefault -gt $onHello -and $ask -gt $toDefault) 'Hello is not asked on Default with the stage stepped back first'
        Assert-True ($text -match "if \(\`$own\) \{ try \{ \[void\]\`$native::SwitchTo\(\`$Desktop\) \} catch \{ \} \}\s+if \(\`$OnHello\) \{ try \{ & \`$OnHello \`$false \}") 'a PIN not verified does not bring the greeter''s desktop back'
        $greeterText = Get-Content -Raw -LiteralPath $greeter
        Assert-True ($greeterText -match '-FirstMode \(Get-VivacLockMode\) -PreviewSeconds \$Preview -OnShown \$shown -OnHello \$hello') 'the greeter does not ask first what the session''s lock asks'
        Assert-True ($greeterText -notmatch '(?m)^\s+\$shared\.StageDown = \$true\s*$[\s\S]*PriorityClass = ''Normal''') 'the stage comes down before the greeter ends'
        $module = Get-Content -Raw -LiteralPath (Join-Path $root 'lib\Greeter.psm1')
        Assert-True ($module -match '\$Shared\.StageHwnd = \[long\]') 'the stage does not hand out its window for Hello''s prompt to be owned by'
        Assert-True ($module -notmatch 'Topmost = -not') 'the stage still steps back for Hello, leaving the desktop in reach'
        Assert-True ($text -match '\$owner = \[IntPtr\]\[long\]\$stage') 'Hello''s prompt is not owned by the stage'
        Assert-True ($text -match 'Start-HelloVerification \$owner') 'Hello is asked for the lock''s own window instead of the owner chosen'
        Assert-True ($greeterText -match 'if \(\$On\) \{ \$Shared\.StageHwnd \}') 'the greeter does not hand the stage''s window to the lock'
        $surfaces = Get-Module Surfaces | Select-Object -First 1
        $p = & $surfaces { Get-Palette }
        $mode = & $surfaces { T 'greeter.hint_mode' }
        $plain = & $surfaces { param($p) Get-GreeterXaml $p } $p
        $only = & $surfaces { param($p) Get-GreeterXaml $p $true } $p
        Assert-True ($plain -match [regex]::Escape($mode)) 'the greeter with the PIN says Tab'
        Assert-True ($only -notmatch [regex]::Escape($mode)) 'the password-only greeter still says Tab'
    }
    Case 'the fallback to Windows'' lock is the desktop-aware one' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $surfaces = Get-Module Surfaces | Select-Object -First 1
        Assert-True ((& $surfaces { $script:LockFallback }).ToString() -match 'Invoke-VivacLockFallback') 'the cover''s grace would lock without leaving the greeter''s desktop'
        $text = Get-Content -Raw -LiteralPath (Join-Path $root 'lib\Surfaces.psm1')
        Assert-True ($text -notmatch '\[void\]\$native::LockWorkStation\(\); & \$finish') 'a hand-over to Windows'' lock that does not leave the desktop first'
    }
    Case 'the lock on its own desktop takes the screen back from another desktop of the session, and cedes only to the secure screen' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $native = Get-LockNative
        Assert-True ($native::SwitchTo('Default')) 'the lock cannot switch to a desktop by name'
        Assert-True (-not $native::SwitchTo('vivac-no-such-desktop')) 'a desktop that is not there was switched to'
        $text = Get-Content -Raw -LiteralPath (Join-Path $root 'lib\Surfaces.psm1')
        Assert-True ($text -match '\$own -and \$where -eq ''Default'' -and \$state\.Retaken -lt 20 -and \$native::SwitchTo\(\$Desktop\)') 'the tick does not take the screen back from Default only, before ceding'
        Assert-True ($text -match '-not \$state\.Busy -and \$state\.OnOwn -and -not \$native::OnDesktop\(\$Desktop\)') 'the tick looks at the desktops before the greeter has switched to its own'
        $onShown = $text.IndexOf('if ($OnShown) { try { & $OnShown }')
        Assert-True ($onShown -gt 0 -and $text.IndexOf('$state.OnOwn = $true', $onShown) -gt $onShown) 'OnOwn is not set right after -OnShown has run'
    }
    Case 'the screen goes black as soon as the watchdog is up, the greeter is built behind it with Default on screen, and shown once drawn' {
        # A window is composed only once the programs' desktop has been on
        # screen after its creation: the stage covers Default while the greeter
        # is built, and the switch to the greeter's desktop is the lock's own
        # on-shown callback.
        $stage = Invoke-VivacGreeterStage @{} -NoShow
        Assert-Equal ([System.Windows.Forms.Screen]::AllScreens.Count) @($stage).Count 'not a stage window per screen'
        foreach ($w in $stage) { Assert-True $w.Topmost 'a stage window that is not topmost'; Assert-Equal 'Black' ([string]$w.Background.Color.ToString() -replace '#FF000000', 'Black') 'a stage window that is not black'; $w.Close() }
        $text = Get-Content -Raw -LiteralPath $greeter
        $watchdog = $text.IndexOf('[Diagnostics.Process]::Start($psi)')
        $stageStart = $text.IndexOf('Invoke-VivacGreeterStage $Shared')
        $surfaces = $text.IndexOf("Import-Module (Join-Path `$Root 'lib\Surfaces.psm1')")
        Assert-True ($watchdog -gt 0 -and $watchdog -lt $stageStart -and $stageStart -lt $surfaces) 'the stage is not between the watchdog and the lock''s modules'
        $shown = $text.IndexOf('$shown = {')
        $wait = $text.IndexOf('Wait-VivacDispatcher 500', $shown)
        $switch = $text.IndexOf('Wait-VivacDesktopSwitch $Own $Desktop 20', $shown)
        Assert-True ($shown -gt 0 -and $wait -gt $shown -and $switch -gt $wait) 'the lock''s on-shown does not wait, answering, before the switch to the greeter''s desktop'
        $t = [Diagnostics.Stopwatch]::StartNew(); Wait-VivacDispatcher 200
        Assert-True ($t.ElapsedMilliseconds -ge 180 -and $t.ElapsedMilliseconds -lt 2000) "the dispatcher wait did not wait: $($t.ElapsedMilliseconds) ms"
        Assert-True ($text -notmatch '(?m)^\s+\$native::Switch\(\$Own\)\s*$') 'the greeter''s desktop is switched to before its windows have drawn'
        Assert-True ($text -notmatch 'Wait-VivacDesktopSwitch \$flip') 'the screen still goes to a flip desktop first'
        Assert-True ($text -match '\$shared\.StageDown = \$true') 'the stage never comes down'
        Assert-True ($text -match "PriorityClass = 'High'") 'the greeter does not hurry at sign-in'
        Assert-True ($text -match "PriorityClass = 'Normal'") 'the greeter never stands down from high priority'
        # No desktop can be switched to with no handle: it tries for the time given, then says so.
        $t = [Diagnostics.Stopwatch]::StartNew()
        Assert-True (-not (Wait-VivacDesktopSwitch ([IntPtr]::Zero) 'vivac-no-such-desktop' 1)) 'a switch that cannot happen was reported done'
        Assert-True ($t.Elapsed.TotalSeconds -ge 0.9 -and $t.Elapsed.TotalSeconds -lt 5) "it did not try for the time given: $($t.Elapsed.TotalSeconds) s"
        Assert-Equal 'Default' (Get-VivacDesktopNative)::InputDesktopName() 'the screen left Default'
    }
    Case 'one greeter at a time: a second one ends at once, touching nothing' {
        $first = Enter-VivacGreeterSingleton
        try {
            Assert-True ($null -ne $first) 'the first greeter did not get the singleton'
            Assert-True ($null -eq (Enter-VivacGreeterSingleton)) 'a second greeter in the same process got it too'
            Remove-Item -LiteralPath $locks -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
            Invoke-Greeter
            Assert-True ((Get-Content -Raw -LiteralPath $log) -match 'a greeter is already up') 'the second greeter did not say why it ended'
            Assert-True (-not (Test-Path -LiteralPath $locks)) 'the second greeter locked'
            Assert-True ($null -eq (Get-VivacLockMarker)) 'the second greeter left a marker'
        } finally { $first.ReleaseMutex(); $first.Dispose() }
        $again = Enter-VivacGreeterSingleton
        Assert-True ($null -ne $again) 'the singleton was not free again once released'
        $again.ReleaseMutex(); $again.Dispose()
    }
    Case 'the watchdog''s script brings Default back and locks only when the greeter went without unlocking' {
        $script = Get-VivacGreeterWatchdogScript 4242 'vivac-greeter' 'C:\state\session-locked' 'C:\state\lock.log' 123456789
        Assert-True ($script -match 'Get-Process -Id 4242') 'it does not wait for the greeter'
        Assert-True ($script -match '\[long\]123456789') 'it does not tell the greeter''s process from one that got its pid after it'
        Assert-True ($script -match 'StartTime\.ToFileTimeUtc\(\) -ne') 'it does not compare the start time'
        $greeterText = Get-Content -Raw -LiteralPath $greeter
        Assert-True ($greeterText -match 'Get-VivacGreeterWatchdogScript \$PID \$desktop \$paths\.LockMarker \$log \(\[Diagnostics\.Process\]::GetCurrentProcess\(\)\.StartTime\.ToFileTimeUtc\(\)\)') 'the greeter does not give the watchdog its start time'
        Assert-True ($greeterText -notmatch 'EncodedCommand') 'the watchdog still runs from an encoded command line'
        Assert-True ($greeterText -match '-File `"\$watchFile`"') 'the watchdog does not run from its file'
        Assert-True ($greeterText -match "Join-Path \`$state 'greeter-watchdog\.ps1'") 'the watchdog''s file is not in the state folder'
        Assert-True ($script -match "InputDesktopName\(\) -like 'vivac-greeter\*'") 'it does not look for either of the greeter''s desktops'
        Assert-True ($script -match "-match '\^4242 '") 'it does not look at the greeter''s own marker'
        Assert-True ($script -match 'SwitchToDefault') 'it does not bring Default back'
        Assert-True ($script -match 'LockWorkStation') 'it does not lock'
        $ok = $false
        try { [void][ScriptBlock]::Create($script); $ok = $true } catch { }
        Assert-True $ok 'the watchdog script does not parse'
    }
    Case 'no-greeter skips the greeter and locks with Windows at once' {
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'no-greeter') -Value '' -Encoding ASCII
        Remove-Item -LiteralPath $locks -ErrorAction SilentlyContinue
        Invoke-Greeter
        Assert-True (Test-Path -LiteralPath $locks) 'Windows was not locked'
        Assert-True ((Get-Content -Raw -LiteralPath $log) -match 'no-greeter is set') 'the log does not say why'
        Remove-Item -LiteralPath (Join-Path $state 'no-greeter') -Force
    }
    Case 'a sign-in the guard settled gets no greeter and no second lock' {
        Remove-Item -LiteralPath $locks -ErrorAction SilentlyContinue
        Write-VivacSigninMarker (Join-Path $state 'signin-guard') 'locked'
        Invoke-Greeter
        Assert-True (-not (Test-Path -LiteralPath $locks)) 'locked twice'
        Assert-True ((Get-Content -Raw -LiteralPath $log) -match 'settled by the guard \(locked\)') 'the log does not say the guard settled it'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $state 'signin-guard'))) 'the guard''s marker was left behind'
        Assert-True ($null -eq (Get-VivacLockMarker)) 'a lock marker was left behind'
    }
    Case 'the task runs the greeter at sign-in, normal level, high priority' {
        $out = [string](& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $greeter -Register -DryRun)
        Assert-True ($out -match 'lock-at-signin') 'not the sign-in task'
        Assert-True ($out -match 'vivac-greeter\.ps1') 'not this script'
        Assert-True ($out -match 'normal level, priority 1') 'not high priority at the normal level'
        Assert-True ($out -notmatch 'LockAtStart') 'still the host with -LockAtStart'
        $apply = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\apply-system.ps1')
        Assert-True ($apply -match "vivac-greeter\.ps1'\) -Register") '-AutoLogin does not register the greeter'
        Assert-True ($apply -notmatch '-LockAtStart"') '-AutoLogin still registers the host with -LockAtStart'
    }
    Case 'a host asked to hold the sign-in hands it to the greeter''s own process, and holds it itself only when it cannot' {
        $line = Start-VivacSigninGreeter -NoStart
        Assert-True ($line -match '^conhost\.exe --headless powershell\.exe .* -File "[^"]*\\bin\\vivac-greeter\.ps1"$') "not the greeter's command line: $line"
        $daemon = Get-Content -Raw -LiteralPath (Join-Path $root 'bin\vivac-daemon.ps1')
        $hand = $daemon.IndexOf('Start-VivacSigninGreeter')
        $settle = $daemon.IndexOf('= Get-VivacSigninSettlement ')
        $cover = $daemon.IndexOf('Show-VivacLockCover')
        Assert-True ($hand -gt 0 -and $hand -lt $settle -and $settle -lt $cover) 'the host does not hand over before holding the sign-in itself'
        Assert-True ($daemon -match '\[void\]\(Start-VivacSigninGreeter\); \$LockAtStart = \$false') 'a started greeter does not stand the host''s own lock down'
        # Before the host's own modules (twenty seconds at a crowded sign-in) and before its singleton.
        $surfaces = $daemon.IndexOf("Import-Module (Join-Path `$root 'lib\Surfaces.psm1')")
        $mutex = $daemon.IndexOf("'Local\vivac-daemon'")
        Assert-True ($hand -lt $surfaces) 'the host loads its modules before handing over'
        Assert-True ($hand -lt $mutex) 'a host that ends for another one up would never hand over'
    }
    Case 'a host started without the lock leaves a live marker of another process alone' {
        $sleeper = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Milliseconds 500
            $start = $sleeper.StartTime.ToFileTimeUtc()
            Write-VivacFile -Path (Get-VivacPaths).LockMarker -Text "$($sleeper.Id) start $start`n"
            Assert-True ($null -ne (Get-VivacLockMarker)) 'the marker of a live process reads as stale'
            Reset-VivacLockMarker
            Assert-True (Test-Path -LiteralPath (Get-VivacPaths).LockMarker) 'the greeter''s marker was taken from under it'
        } finally { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
        Reset-VivacLockMarker
        Assert-True (-not (Test-Path -LiteralPath (Get-VivacPaths).LockMarker)) 'the marker of a dead process stayed'
    }
} finally {
    Remove-TempProfile $dir
}
Complete-Cases
