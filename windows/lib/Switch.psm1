# Switching between the two systems (docs/bridge.md at the product root,
# "Reboot into the other system"): the token each side leaves for the other.
# One line, `vivac-switch 1 <unix time>`; honoured when written in the last
# fifteen minutes, and taken away whether honoured or not, so it opens one
# sign-in at most. It carries a time and nothing else: what it opens is
# decided by the side that reads it.
#
# Linux leaves it in %LOCALAPPDATA%\vivac\switch-arrival, where the host
# (bin\vivac-daemon.ps1 -LockAtStart) takes it in place of its greeter;
# Restart in Linux (bin\vivac-reboot-other.ps1) leaves it on the EFI
# partition, at \EFI\vivac\switch-to-linux. Files only: no network, no
# firmware, so the elevated task's protected copy can carry it as it is.

Set-StrictMode -Version 2.0

$script:MaxAge = 900
$script:MaxAhead = 120

function Get-VivacUnixTime { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Get-VivacSwitchToken([long]$Now = (Get-VivacUnixTime)) { "vivac-switch 1 $Now" }

function Test-VivacSwitchToken([string]$Text, [long]$Now = (Get-VivacUnixTime)) {
    if ($null -eq $Text) { return $false }
    $line = @($Text -split "`r?`n")[0]
    if ($line -notmatch '^vivac-switch 1 ([0-9]{1,12})$') { return $false }
    $age = $Now - [long]$Matches[1]
    ($age -le $script:MaxAge) -and ($age -ge -$script:MaxAhead)
}

function Write-VivacSwitchToken([string]$Path, [long]$Now = (Get-VivacUnixTime)) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllBytes($tmp, [Text.Encoding]::ASCII.GetBytes((Get-VivacSwitchToken $Now) + "`n"))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# True when a fresh token was there. The token goes either way; one that
# cannot be removed is not honoured, or it could open a second sign-in.
function Use-VivacSwitchArrival([string]$Path, [long]$Now = (Get-VivacUnixTime)) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = ''
    try { $text = [IO.File]::ReadAllText($Path) } catch { }
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $false }
    if (Test-Path -LiteralPath $Path) { return $false }
    Test-VivacSwitchToken $text $Now
}

Export-ModuleMember -Function Get-VivacUnixTime, Get-VivacSwitchToken, Test-VivacSwitchToken, Write-VivacSwitchToken, Use-VivacSwitchArrival
