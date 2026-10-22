<#
.SYNOPSIS
  vivac mouse: one keyboard and mouse for this machine and the other one,
  Linux or Windows, through lan-mouse.

.DESCRIPTION
  The Windows side of docs/bridge.md, "One keyboard and mouse". lan-mouse
  does the work (UDP 4242, DTLS); vivac only writes its config.toml from
  %LOCALAPPDATA%\vivac\mouse.conf and runs `lan-mouse daemon` as the sign-in
  task \vivac\mouse, and only while it is enabled. Each side lists the
  other's certificate fingerprint; lan-mouse refuses any other.

    enable            write the config, register \vivac\mouse and start it
    disable           remove that task and stop lan-mouse
    toggle            enable when off, disable when on (the menu)
    status            on or off, the other machine, the fingerprints
    config -Peer HOST -Side left|right|top|bottom [-Fingerprint FP] [-Port N]
                      where the other machine is, seen from this one
    trust FP          accept the other machine's certificate fingerprint
    fingerprint       print this machine's certificate fingerprint
    pair              print what the other machine needs: fingerprint, name, side

  -DryRun says what enable, disable, toggle, config and trust would write
  and run, and changes nothing. lan-mouse is the winget package
  feschber.LanMouse (bootstrap.ps1 -Mouse); VIVAC_LAN_MOUSE names another
  lan-mouse.exe. Other machines reach it only through the firewall rule
  `apply-system.ps1 -Mouse` adds: private networks, local subnet, UDP 4242.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Verb,
    [Parameter(Position = 1)][string]$Value,
    [string]$Peer,
    [string]$Side,
    [string]$Fingerprint,
    [string]$Port,
    [switch]$DryRun,
    # Say how it went in a notification, not on a console (the menu runs
    # without one).
    [switch]$Notify
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Mouse.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

$taskPath = '\vivac\'
$taskName = 'mouse'

# A line for the person: on the console, or as a card when the menu ran this.
function Say-Mouse([string]$Text) {
    if (-not $Notify) { $Text; return }
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    Import-Module (Join-Path $root 'lib\Toasts.psm1') -Force
    Show-VivacToast (T 'mouse.title') $Text 'vivac' '' '' $null
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $t.Add_Tick({ if (-not (& (Get-Module Toasts) { $script:Stack.Count })) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } })
    $t.Start()
    [Windows.Threading.Dispatcher]::Run()
}

function Write-MouseConfig($Settings) {
    if ($DryRun) {
        T 'mouse.would_write' @((Join-Path (Get-VivacLanMouseDir) 'config.toml'))
        (Get-VivacLanMouseToml $Settings).TrimEnd("`n")
        return
    }
    Save-VivacMouse $Settings
}

# lan-mouse daemons, and only them: a lan-mouse window started by hand stays.
function Get-LanMouseDaemons {
    @(Get-CimInstance Win32_Process -Filter "Name = 'lan-mouse.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '\sdaemon\s*$' })
}

function Stop-LanMouse {
    foreach ($p in Get-LanMouseDaemons) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

# The sign-in task, at the normal level, lan-mouse without a console window.
# lan-mouse reads its config at start only, so a running one is restarted.
function Start-MouseTask([string]$Exe) {
    $runner = "--headless `"$Exe`" daemon"
    if ($DryRun) {
        T 'mouse.would_run' @("Register-ScheduledTask $taskPath$taskName (AtLogOn): conhost.exe $runner")
        T 'mouse.would_run' @("Start-ScheduledTask $taskPath$taskName")
        return
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $runner
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settingsObj = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settingsObj -Force | Out-Null
    Stop-LanMouse
    Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName
}

function Restart-IfEnabled($Settings) {
    if ($Settings.enabled -ne 'yes') { return }
    $exe = Find-VivacLanMouse
    if ($exe) { Start-MouseTask $exe }
}

function Invoke-Enable {
    $exe = Find-VivacLanMouse
    if (-not $exe) { [Console]::Error.WriteLine('vivac-mouse: ' + (T 'mouse.no_binary')); exit 1 }
    $s = Read-VivacMouseConf
    $s.enabled = 'yes'
    Write-MouseConfig $s
    Start-MouseTask $exe
    if (-not $s.Contains('peer') -or -not $s.Contains('fingerprint')) { Say-Mouse (T 'mouse.on_unpaired'); return }
    Say-Mouse (T 'mouse.on' @($s.peer, $s['side']))
}

function Invoke-Disable {
    $s = Read-VivacMouseConf
    $s.enabled = 'no'
    if ($DryRun) {
        T 'mouse.would_write' @(Get-VivacMouseConfPath)
        T 'mouse.would_run' @("Unregister-ScheduledTask $taskPath$taskName")
        T 'mouse.would_run' @('Stop-Process lan-mouse daemon')
    } else {
        Write-VivacFile -Path (Get-VivacMouseConfPath) -Text (Get-VivacMouseConfText $s)
        Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Stop-LanMouse
    }
    Say-Mouse (T 'mouse.off')
}

function Fail([string]$Key, [object[]]$Values = @()) {
    [Console]::Error.WriteLine('vivac-mouse: ' + (T $Key $Values))
    exit 2
}

switch ($Verb) {
    'enable' { Invoke-Enable }
    'disable' { Invoke-Disable }
    'toggle' { if ((Read-VivacMouseConf).enabled -eq 'yes') { Invoke-Disable } else { Invoke-Enable } }
    'config' {
        if (-not $Peer -or -not $Side) { Fail 'mouse.usage_config' }
        $s = Read-VivacMouseConf
        $p = ConvertTo-VivacMousePeer $Peer
        if (-not $p) { Fail 'mouse.bad_peer' @($Peer) }
        if ((Get-VivacMouseSides) -notcontains $Side) { Fail 'mouse.bad_side' @($Side) }
        $s.peer = $p
        $s.side = $Side.ToLowerInvariant()
        if ($Fingerprint) {
            $f = ConvertTo-VivacFingerprint $Fingerprint
            if (-not $f) { Fail 'mouse.bad_fingerprint' }
            $s.fingerprint = $f
        }
        if ($Port) {
            $n = ConvertTo-VivacMousePort $Port
            if (-not $n) { Fail 'mouse.bad_port' @($Port) }
            $s.port = [string]$n
        }
        Write-MouseConfig $s
        if (-not $DryRun) { T 'mouse.configured' @($p, $s.side) }
        Restart-IfEnabled $s
    }
    'trust' {
        $f = ConvertTo-VivacFingerprint $Value
        if (-not $f) { Fail 'mouse.bad_fingerprint' }
        $s = Read-VivacMouseConf
        $s.fingerprint = $f
        Write-MouseConfig $s
        if (-not $DryRun) { T 'mouse.trusted' @($f) }
        Restart-IfEnabled $s
    }
    'fingerprint' {
        $mine = Get-VivacOwnFingerprint
        if (-not $mine) { [Console]::Error.WriteLine('vivac-mouse: ' + (T 'mouse.no_certificate' @(Join-Path (Get-VivacLanMouseDir) 'lan-mouse.pem'))); exit 1 }
        $mine
    }
    # What to type on the other machine. The side there is the opposite of
    # the side here: with the other machine on the right of this one, this
    # one is on its left.
    'pair' {
        $mine = Get-VivacOwnFingerprint
        if (-not $mine) { [Console]::Error.WriteLine('vivac-mouse: ' + (T 'mouse.no_certificate' @(Join-Path (Get-VivacLanMouseDir) 'lan-mouse.pem'))); exit 1 }
        $s = Read-VivacMouseConf
        $there = 'SIDE'
        if ($s.Contains('side')) { $there = Get-VivacMouseOpposite $s.side }
        $name = $env:COMPUTERNAME
        T 'mouse.pair_this' @($name, $mine)
        T 'mouse.pair_other'
        "  vivac-mouse config --peer $name --side $there --fingerprint $mine"
        "  bin\vivac-mouse.ps1 config -Peer $name -Side $there -Fingerprint $mine"
        if ($there -eq 'SIDE') { T 'mouse.pair_side' }
    }
    'status' {
        $s = Read-VivacMouseConf
        $state = 'inactive'
        if (@(Get-LanMouseDaemons).Count) { $state = 'active' }
        if ($s.enabled -eq 'yes') { T 'mouse.status_on' @($state) } else { T 'mouse.status_off' @($state) }
        if (-not (Find-VivacLanMouse)) { T 'mouse.no_binary' }
        if ($s.Contains('peer') -and $s.Contains('side')) { T 'mouse.status_peer' @($s.peer, $s.side, $s.port) } else { T 'mouse.status_peer_none' }
        $trusted = '-'
        if ($s.Contains('fingerprint')) { $trusted = $s.fingerprint }
        T 'mouse.status_trusted' @($trusted)
        $mine = Get-VivacOwnFingerprint
        if (-not $mine) { $mine = '-' }
        T 'mouse.status_mine' @($mine)
    }
    default {
        Get-Help $PSCommandPath -Detailed | Out-String | Write-Host
        exit 2
    }
}
exit 0
