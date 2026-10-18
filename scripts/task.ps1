<#
.SYNOPSIS
  Run or schedule a local task described as data, not as a script.

.DESCRIPTION
  The Windows counterpart of the source's workstation-task-runner and its
  systemd templates. A task is a JSON file in %APPDATA%\vivac\tasks\<name>.json:

    {
      "command": ["C:\\Windows\\System32\\cmd.exe", "/c", "echo", "hello"],
      "working_directory": "~",
      "environment": { "KEY": "value" }
    }

  command is an argument array, run directly and never through a shell, so
  nothing in it is interpreted. Secrets do not belong in the file: point the
  task at a credential manager or an environment loader instead.

  -Register puts it in the Task Scheduler under \vivac\, as the current user,
  with no elevation: weekly with a random delay (the source's persistent
  weekly timer), daily, or at sign-in.

.EXAMPLE
  scripts\task.ps1 -Name example -Run
.EXAMPLE
  scripts\task.ps1 -Name example -Register -Schedule Weekly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$Run,
    [switch]$Register,
    [switch]$Unregister,
    [ValidateSet('Weekly', 'Daily', 'Logon')][string]$Schedule = 'Weekly',
    [switch]$DryRun
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force

function Fail([string]$Message) { Write-Error "task: $Message"; exit 2 }

if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { Fail 'expected one safe task name' }
$path = Join-Path (Get-VivacPaths).Config "tasks\$Name.json"

# The quoting rules of CommandLineToArgvW, so each array element reaches the
# program as exactly one argument, whatever it contains.
function ConvertTo-CommandLineArgument([string]$Arg) {
    if ($Arg -and $Arg -notmatch '[\s"]') { return $Arg }
    $out = '"'
    $slashes = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') { $out += ('\' * ($slashes * 2 + 1)) + '"'; $slashes = 0; continue }
        $out += ('\' * $slashes) + $c
        $slashes = 0
    }
    $out + ('\' * ($slashes * 2)) + '"'
}

function Read-Task {
    if (-not (Test-Path -LiteralPath $path)) { Fail "no task at $path" }
    try { $t = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { Fail "cannot read valid task configuration: $($_.Exception.Message)" }
    $cmd = @($t.command)
    if (-not $cmd.Count -or @($cmd | Where-Object { -not ($_ -is [string]) -or -not $_ }).Count) { Fail 'command must be a non-empty JSON array of strings' }
    $environment = @{}
    if ($t.PSObject.Properties['environment'] -and $t.environment) {
        foreach ($p in $t.environment.PSObject.Properties) {
            if (-not ($p.Value -is [string])) { Fail 'environment must map strings to strings' }
            $environment[$p.Name] = $p.Value
        }
    }
    $wd = (Get-VivacPaths).Profile
    if ($t.PSObject.Properties['working_directory'] -and $t.working_directory) {
        $wd = ([string]$t.working_directory) -replace '^~', (Get-VivacPaths).Profile
    }
    if (-not (Test-Path -LiteralPath $wd -PathType Container)) { Fail 'working_directory does not exist' }
    $exe = $cmd[0]
    if (-not [IO.Path]::IsPathRooted($exe)) {
        $found = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { Fail "executable not found: $exe" }
        $exe = $found.Source
    } elseif (-not (Test-Path -LiteralPath $exe)) { Fail "executable not found: $exe" }
    [pscustomobject]@{ Exe = $exe; Args = @($cmd | Select-Object -Skip 1); Env = $environment; Dir = $wd }
}

if ($Run) {
    $t = Read-Task
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $t.Exe
    $psi.Arguments = ($t.Args | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    $psi.WorkingDirectory = $t.Dir
    $psi.UseShellExecute = $false
    foreach ($k in $t.Env.Keys) { $psi.EnvironmentVariables[$k] = $t.Env[$k] }
    if ($DryRun) { "would run: $($psi.FileName) $($psi.Arguments)  (in $($psi.WorkingDirectory))"; return }
    $p = [Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    exit $p.ExitCode
}

$taskPath = '\vivac\'
$taskName = "task-$Name"
if ($Unregister) {
    if ($DryRun) { "would unregister $taskPath$taskName"; return }
    Unregister-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Confirm:$false
    return
}
if ($Register) {
    [void](Read-Task)
    $runner = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Name $Name -Run"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $runner
    $trigger = switch ($Schedule) {
        'Weekly' { New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:00' -RandomDelay (New-TimeSpan -Hours 1) }
        'Daily'  { New-ScheduledTaskTrigger -Daily -At '12:00' -RandomDelay (New-TimeSpan -Minutes 30) }
        'Logon'  { New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME" }
    }
    # StartWhenAvailable is the source's Persistent=true: a run missed while
    # the machine was off happens at the next chance.
    $settingsObj = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    if ($DryRun) { "would register $taskPath$taskName ($Schedule): powershell.exe $runner"; return }
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName -Action $action -Trigger $trigger -Settings $settingsObj -Force | Out-Null
    "registered $taskPath$taskName ($Schedule)"
    return
}
Get-Help $PSCommandPath
