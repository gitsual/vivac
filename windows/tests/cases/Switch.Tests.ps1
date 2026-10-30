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
Case 'the host skips its greeter only on a fresh arrival' {
    $daemon = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'bin\vivac-daemon.ps1')
    Assert-True ($daemon -match 'Use-VivacSwitchArrival') 'the host never looks for an arrival'
}
Case 'Restart in Linux leaves the token on the EFI partition before BootNext' {
    $tool = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'bin\vivac-reboot-other.ps1')
    $leave = $tool.IndexOf('Write-VivacEspSwitchToken')
    $boot = $tool.IndexOf("bootsequence `$e.Id")
    Assert-True ($leave -gt 0 -and $leave -lt $boot) 'the token is not left before bootsequence'
    Assert-True ($tool -match "'lib\\Switch.psm1'") 'the protected copy lacks lib\Switch.psm1'
}

Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
Complete-Cases
