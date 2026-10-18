# The programs vivac drives: where they are, whether they run, and how to
# start, stop and talk to them without ever waiting forever on one.

Set-StrictMode -Version 2.0

$script:Apps = @{
    # The window manager itself, and its command-line client: two programs
    # with the same name, the client in a cli folder of its own on the PATH.
    glazewm = @{ Process = 'glazewm'; Command = $null; Paths = @('%ProgramFiles%\glzr.io\GlazeWM\glazewm.exe', '%LOCALAPPDATA%\Programs\glzr.io\GlazeWM\glazewm.exe') }
    glazewmcli = @{ Process = 'glazewm'; Command = 'glazewm'; Paths = @('%ProgramFiles%\glzr.io\GlazeWM\cli\glazewm.exe') }
    zebar   = @{ Process = 'zebar'; Command = 'zebar'; Paths = @('%ProgramFiles%\glzr.io\Zebar\zebar.exe', '%LOCALAPPDATA%\Programs\glzr.io\Zebar\zebar.exe') }
    flow    = @{ Process = 'Flow.Launcher'; Command = $null; Paths = @('%LOCALAPPDATA%\FlowLauncher\Flow.Launcher.exe') }
    nvim    = @{ Process = 'nvim'; Command = 'nvim'; Paths = @('%ProgramFiles%\Neovim\bin\nvim.exe') }
    wt      = @{ Process = 'WindowsTerminal'; Command = 'wt'; Paths = @('%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe') }
}

function Find-VivacApp([string]$Name) {
    $app = $script:Apps[$Name]
    if (-not $app) { throw "vivac: unknown app '$Name'" }
    if ($app.Command) {
        $cmd = Get-Command $app.Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    foreach ($p in $app.Paths) {
        $full = [Environment]::ExpandEnvironmentVariables($p)
        if (Test-Path -LiteralPath $full) { return $full }
    }
    $null
}

function Test-VivacAppRunning([string]$Name) {
    [bool](Get-Process -Name $script:Apps[$Name].Process -ErrorAction SilentlyContinue)
}

# Returns whether it was running, so the caller can start it again.
function Stop-VivacApp([string]$Name) {
    $procs = @(Get-Process -Name $script:Apps[$Name].Process -ErrorAction SilentlyContinue)
    if (-not $procs.Count) { return $false }
    foreach ($p in $procs) {
        [void]$p.CloseMainWindow()
    }
    foreach ($p in $procs) {
        if (-not $p.WaitForExit(3000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    $true
}

function Start-VivacApp([string]$Name) {
    $exe = Find-VivacApp $Name
    if (-not $exe) { return $false }
    Start-Process -FilePath $exe -WindowStyle Hidden | Out-Null
    $true
}

function Restart-VivacApp([string]$Name) {
    [void](Stop-VivacApp $Name)
    [void](Start-VivacApp $Name)
}

# GlazeWM's CLI talks to the running window manager over its IPC port. Bounded
# to five seconds: a wedged IPC must not freeze a theme switch.
function Invoke-GlazeWM([string[]]$Arguments, [int]$TimeoutMs = 5000) {
    $exe = Find-VivacApp 'glazewmcli'
    if (-not $exe -or -not (Test-VivacAppRunning 'glazewm')) { return $null }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        return $null
    }
    $stdout.Result
}

# The resident host of vivac's surfaces (bin/vivac-daemon.ps1). Found by the
# id it writes at start rather than by command line: started by GlazeWM it
# runs above the normal integrity level, where a normal process cannot read
# its command line at all.
function Get-VivacDaemonProcess {
    Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
    $pidFile = Join-Path (Get-VivacPaths).State 'daemon.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return @() }
    $id = 0
    if (-not [int]::TryParse(([IO.File]::ReadAllText($pidFile)).Trim(), [ref]$id)) { return @() }
    @(Get-Process -Id $id -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'powershell' })
}

function Test-VivacDaemonAlive([int]$Id) {
    [bool](Get-Process -Id $Id -ErrorAction SilentlyContinue)
}

function Send-VivacVerb([string]$Verb, [int]$TimeoutMs = 1000) {
    Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
    $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', (Get-VivacPipeName), [IO.Pipes.PipeDirection]::Out)
    try {
        $client.Connect($TimeoutMs)
        $bytes = [Text.Encoding]::ASCII.GetBytes("$Verb`n")
        $client.Write($bytes, 0, $bytes.Length)
        $true
    } catch { $false } finally { $client.Dispose() }
}

# A host started before a deploy keeps the code it loaded; it is asked to
# quit and started again so the surfaces it shows are the current ones.
#
# Asked to quit through its pipe first. One that does not answer is stopped;
# when this process may not stop it (it runs above our level), GlazeWM, which
# runs at that level, is asked to. The new host is started through GlazeWM
# too when GlazeWM is running, so it gets the same level: from there its
# keyboard hook also sees the keys typed into administrator windows.
function Restart-VivacDaemon([switch]$StartIfStopped) {
    $running = @(Get-VivacDaemonProcess)
    if (-not $running.Count -and -not $StartIfStopped) { return $false }
    if ($running.Count) {
        [void](Send-VivacVerb 'quit')
        foreach ($p in $running) {
            $deadline = (Get-Date).AddSeconds(3)
            while ((Test-VivacDaemonAlive $p.Id) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            if (Test-VivacDaemonAlive $p.Id) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            if (Test-VivacDaemonAlive $p.Id) { [void](Invoke-GlazeWM @('command', 'shell-exec', 'taskkill.exe', '/PID', "$($p.Id)", '/F')); Start-Sleep -Milliseconds 800 }
        }
    }
    $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\vivac-daemon.ps1'
    $launch = @('conhost.exe', '--headless', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
    if (Test-VivacAppRunning 'glazewm') {
        [void](Invoke-GlazeWM (@('command', 'shell-exec') + $launch))
    } else {
        Start-Process -FilePath $launch[0] -ArgumentList ($launch[1..6] + "`"$script`"") -WindowStyle Hidden | Out-Null
    }
    $true
}

# The window manager's state, parsed. $null when GlazeWM is not running.
function Get-GlazeWMState([string]$What) {
    $out = Invoke-GlazeWM @('query', $What)
    if (-not $out) { return $null }
    try { ($out | ConvertFrom-Json).data } catch { $null }
}

Export-ModuleMember -Function *
