# Switching between the two systems (lib/Switch.psm1, docs/bridge.md "Reboot
# into the other system"): the token each side leaves for the other, one line
# `vivac-switch 1 <unix time>`, honoured only when fresh and only once.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Switch.psm1') -Force

$now = [long]1800000000
$dir = Join-Path ([IO.Path]::GetTempPath()) ("vivac-switch-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$path = Join-Path $dir 'switch-arrival'

Case 'the token is one line with the time it was written' {
    Assert-Equal "vivac-switch 1 $now" (Get-VivacSwitchToken $now)
}
Case 'a fresh token is accepted, a stale, future or foreign one is not' {
    Assert-True (Test-VivacSwitchToken "vivac-switch 1 $($now - 60)" $now) 'one minute old'
    Assert-True (Test-VivacSwitchToken "vivac-switch 1 $($now + 30)" $now) 'clocks thirty seconds apart'
    foreach ($bad in @("vivac-switch 1 $($now - 3600)", "vivac-switch 1 $($now + 3600)", "vivac-switch 2 $now", 'vivac-switch 1 soon', "user=x vivac-switch 1 $now", '')) {
        Assert-True (-not (Test-VivacSwitchToken $bad $now)) "accepted '$bad'"
    }
}
Case 'an arrival with no token is no arrival' {
    Assert-True (-not (Use-VivacSwitchArrival $path $now))
}
Case 'a fresh arrival is honoured once and the token is gone' {
    Write-VivacSwitchToken $path ($now - 120)
    Assert-True (Test-Path -LiteralPath $path) 'the token was not written'
    Assert-True (Use-VivacSwitchArrival $path $now) 'a fresh token was refused'
    Assert-True (-not (Test-Path -LiteralPath $path)) 'the token was left behind'
    Assert-True (-not (Use-VivacSwitchArrival $path $now)) 'honoured twice'
}
Case 'a stale arrival is refused and still taken away' {
    Write-VivacSwitchToken $path ($now - 86400)
    Assert-True (-not (Use-VivacSwitchArrival $path $now)) 'a day-old token was honoured'
    Assert-True (-not (Test-Path -LiteralPath $path)) 'the stale token was left behind'
}
Case 'a token written by Linux (LF, no BOM) is read the same' {
    [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes("vivac-switch 1 $now`n"))
    Assert-True (Use-VivacSwitchArrival $path $now)
}
Case 'the host and the greeter skip their lock only on a settled sign-in or a fresh arrival' {
    foreach ($f in 'bin\vivac-daemon.ps1', 'bin\vivac-greeter.ps1') {
        $text = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) $f)
        Assert-True ($text -match 'Get-VivacSigninSettlement') "$f never asks what the sign-in already is"
    }
    $lib = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'lib\Switch.psm1')
    Assert-True ($lib -match 'Use-VivacSwitchArrival \(Join-Path \$State') 'the settlement never looks for an arrival'
}
$settle = Join-Path $dir 'settle'
Case 'a sign-in is settled by the guard first, then by a token the guard did not claim' {
    New-Item -ItemType Directory -Force -Path $settle | Out-Null
    Assert-Equal $null (Get-VivacSigninSettlement $settle) 'nothing there: nothing settled'
    Write-VivacSigninMarker (Join-Path $settle 'signin-guard') 'locked'
    Assert-Equal 'locked' (Get-VivacSigninSettlement $settle) 'the guard locked'
    Assert-Equal $null (Get-VivacSigninSettlement $settle) 'the marker is read once'
    Write-VivacSwitchToken (Join-Path $settle 'switch-arrival')
    Assert-Equal 'switch' (Get-VivacSigninSettlement $settle) 'a fresh token, no guard: taken here'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $settle 'switch-arrival'))) 'the token was left behind'
    Set-Content -LiteralPath (Join-Path $settle 'signin-guard.installed') -Value 'x'
    Write-VivacSwitchToken (Join-Path $settle 'switch-arrival')
    Assert-Equal $null (Get-VivacSigninSettlement $settle) 'with the guard installed the token is not ours'
    Assert-True (Test-Path -LiteralPath (Join-Path $settle 'switch-arrival')) 'and it is left for the guard'
}
Case 'Restart in Linux leaves the token on the EFI partition before BootNext' {
    $tool = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'bin\vivac-reboot-other.ps1')
    $leave = $tool.IndexOf('Write-VivacEspSwitchToken')
    $boot = $tool.IndexOf("bootsequence `$e.Id")
    Assert-True ($leave -gt 0 -and $leave -lt $boot) 'the token is not left before bootsequence'
    Assert-True ($tool -match "'lib\\Switch.psm1'") 'the protected copy lacks lib\Switch.psm1'
}

# The sign-in guard (bin\vivac-signin-guard.ps1): first thing at sign-in, it
# takes the switch token or locks with Windows' own lock, and leaves the host
# a marker saying which, so the host never adds a second lock on top.
$marker = Join-Path $dir 'signin-guard'
Case 'the guard marker says what was done, fresh and once' {
    Write-VivacSigninMarker $marker 'locked' ($now - 30)
    Assert-Equal 'locked' (Use-VivacSigninMarker $marker $now)
    Assert-Equal $null (Use-VivacSigninMarker $marker $now) 'read twice'
    Write-VivacSigninMarker $marker 'switch' ($now - 3600)
    Assert-Equal $null (Use-VivacSigninMarker $marker $now) 'an hour-old marker was taken'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'the stale marker was left behind'
    [IO.File]::WriteAllText($marker, "vivac-signin open $now")
    Assert-Equal $null (Use-VivacSigninMarker $marker $now) 'an unknown kind was taken'
}

$guard = Join-Path (Get-RepoRoot) 'bin\vivac-signin-guard.ps1'
$state = Join-Path $dir 'state'
$locks = Join-Path $dir 'locks.txt'
$fakeLock = Join-Path $dir 'fake-lock.cmd'
Set-Content -LiteralPath $fakeLock -Value "@echo locked>>`"$locks`"" -Encoding ASCII
function Invoke-Guard {
    $env:VIVAC_LOCALAPPDATA = $dir; $env:VIVAC_SIGNIN_LOCK = $fakeLock
    try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $guard | Out-Null } finally {
        Remove-Item Env:VIVAC_LOCALAPPDATA, Env:VIVAC_SIGNIN_LOCK -ErrorAction SilentlyContinue
    }
}
$vivacState = Join-Path $dir 'vivac'
Case 'the guard locks with Windows when no switch brought this sign-in' {
    Remove-Item -LiteralPath $locks -ErrorAction SilentlyContinue
    Invoke-Guard
    Assert-True (Test-Path -LiteralPath $locks) 'Windows was not locked'
    Assert-Equal 'locked' (Use-VivacSigninMarker (Join-Path $vivacState 'signin-guard'))
}
Case 'the guard takes a fresh switch token and does not lock' {
    Remove-Item -LiteralPath $locks -ErrorAction SilentlyContinue
    Write-VivacSwitchToken (Join-Path $vivacState 'switch-arrival')
    Invoke-Guard
    Assert-True (-not (Test-Path -LiteralPath $locks)) 'locked although a switch brought this sign-in'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $vivacState 'switch-arrival'))) 'the token was left behind'
    Assert-Equal 'switch' (Use-VivacSigninMarker (Join-Path $vivacState 'signin-guard'))
}
Case 'a stale token still locks' {
    Remove-Item -LiteralPath $locks -ErrorAction SilentlyContinue
    Write-VivacSwitchToken (Join-Path $vivacState 'switch-arrival') ((Get-VivacUnixTime) - 86400)
    Invoke-Guard
    Assert-True (Test-Path -LiteralPath $locks) 'a day-old token kept Windows open'
}
Case 'with the guard installed, the token is the guard''s alone' {
    $lib = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'lib\Switch.psm1')
    Assert-True ($lib -match "-not \`$guarded -and \(Use-VivacSwitchArrival") 'the settlement can take the token from under the guard'
    $g = Get-Content -Raw -LiteralPath $guard
    Assert-True ($g -match 'signin-guard.installed') 'registering the guard does not tell the host'
}
Case 'the host and the greeter read the guard before their own cover' {
    foreach ($f in 'bin\vivac-daemon.ps1', 'bin\vivac-greeter.ps1') {
        $text = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) $f)
        $read = $text.IndexOf('= Get-VivacSigninSettlement ')
        $cover = $text.IndexOf('Show-VivacLockCover')
        Assert-True ($read -gt 0 -and $read -lt $cover) "$f decides on its greeter before reading the guard"
    }
}

Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
Complete-Cases
