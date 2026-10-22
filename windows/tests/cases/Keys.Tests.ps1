# The keyboard hook's decisions (lib/VivacKeys.cs), fed key by key without a
# keyboard: what it keeps from Windows, what it lets through, and what it
# sends in its place. Nothing is hooked and nothing is typed; the keys it
# would send are recorded instead.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $root 'lib\VivacKeys.cs'))) -Language CSharp

$down = 0x100; $up = 0x101; $sysDown = 0x104; $sysUp = 0x105
$win = 0x5B; $alt = 0xA4; $tab = 0x09; $keyL = 0x4C; $key1 = 0x31; $keyA = 0x41

function Start-Keys {
    [VivacKeys]::Reset()
    [VivacKeys]::MaskWin = $true
    [VivacKeys]::Sent = New-Object 'System.Collections.Generic.List[string]'
}
function Send-Key([uint32]$Vk, [int]$Msg) { [VivacKeys]::Swallow($Vk, $Vk, 0, $Msg) }

Case 'a Win held when the lock comes up is let go when it is released' {
    Start-Keys
    Assert-True (Send-Key $win $down) 'Win is held back until it is known what it is for'
    Assert-True (Send-Key $key1 $down) 'Win+1 is sent on as a fresh Win press and 1'
    Assert-Equal @('5B:1', '31:0') @([VivacKeys]::Sent) 'sent for Win+1'
    [VivacKeys]::LockMode = $true
    [void](Send-Key $key1 $up)
    [void](Send-Key $win $up)
    Assert-True ([VivacKeys]::Sent -contains '5B:3') 'the Win press sent before the lock must be released, or every key typed into the field is a Win shortcut'
    Assert-True (-not [VivacKeys]::WinHeld) 'the hook still thinks Win is down'
}

Case 'an Alt held when the lock comes up reaches Windows when it is released' {
    Start-Keys
    Assert-True (-not (Send-Key $alt $sysDown)) 'Alt goes through outside the lock'
    [VivacKeys]::LockMode = $true
    Assert-True (Send-Key $keyA $sysDown) 'Alt+A is turned away while the lock is up'
    Assert-True (Send-Key $keyA $sysUp) 'the release of A goes where its press went'
    Assert-True (-not (Send-Key $alt $sysUp)) 'the release of an Alt Windows saw go down must reach Windows'
    Assert-True (-not (Send-Key $keyA $down)) 'A types into the field once Alt is up'
}

Case 'Win+L leaves no key held behind it' {
    Start-Keys
    [void](Send-Key $win $down)
    Assert-True (Send-Key $keyL $down) 'Win+L is vivac''s'
    Assert-True ([VivacKeys]::TakeLock()) 'Win+L asks for the lock'
    [VivacKeys]::LockMode = $true
    Assert-True (Send-Key $keyL $up) 'the release of L stays with vivac'
    Assert-True (Send-Key $win $up) 'the release of Win stays with vivac'
    [VivacKeys]::LockMode = $false
    Assert-True (-not [VivacKeys]::WinHeld) 'Win is still taken as down after the lock'
    Assert-True (-not (Send-Key $keyL $down)) 'the first L after unlocking is lost'
    Assert-True (-not (Send-Key $keyA $down)) 'A after unlocking is sent as Win+A'
    Assert-Equal 0 ([VivacKeys]::Sent.Count) 'nothing is sent in place of any key'
}

Case 'the lock still turns away Alt+Tab and the Win key' {
    Start-Keys
    [VivacKeys]::LockMode = $true
    Assert-True (Send-Key $alt $sysDown) 'Alt'
    Assert-True (Send-Key $tab $sysDown) 'Alt+Tab'
    Assert-True (Send-Key $tab $sysUp) 'the release of Tab'
    Assert-True (Send-Key $alt $sysUp) 'the release of Alt'
    Assert-True (Send-Key $win $down) 'Win'
    Assert-True (Send-Key $win $up) 'the release of Win'
    Assert-True (-not (Send-Key $keyA $down)) 'A types into the field'
    Assert-Equal 0 ([VivacKeys]::Sent.Count) 'nothing is sent in place of any key'
}

Case 'AltGr types into the lock''s field (@ on a Spanish keyboard)' {
    Start-Keys
    [VivacKeys]::LockMode = $true
    $lctrl = 0xA2; $altGr = 0xA5; $key2 = 0x32
    # AltGr arrives as a left Ctrl and a right Alt.
    Assert-True (-not (Send-Key $lctrl $down)) 'the Ctrl half of AltGr'
    Assert-True (-not (Send-Key $altGr $down)) 'AltGr'
    Assert-True (-not (Send-Key $key2 $down)) 'AltGr+2 (@) must reach the field'
    Assert-True (-not (Send-Key $key2 $up)) 'the release of 2'
    Assert-True (Send-Key $tab $down) 'AltGr+Tab is still turned away'
    Assert-True (Send-Key $tab $up) 'the release of Tab'
    Assert-True (-not (Send-Key $altGr $up)) 'the release of AltGr'
    Assert-True (-not (Send-Key $lctrl $up)) 'the release of Ctrl'
    Assert-True (-not (Send-Key $keyA $down)) 'A types into the field'
}

Complete-Cases
