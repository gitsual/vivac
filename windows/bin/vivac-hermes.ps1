<#
.SYNOPSIS
  Hermes Agent, one home for both halves of the dual boot.

.DESCRIPTION
  The Windows side of docs/bridge.md, "Hermes across the dual boot". The
  home (config.yaml, memories\, skills\, SOUL.md, state.db...) is
  %USERPROFILE%\.hermes, on this partition: Hermes uses it natively here and
  Linux reaches it through its mount of this partition, with its own
  ~/.hermes a link to it (vivac-hermes --share, there). Code and tool store
  stay per side, under %LOCALAPPDATA%\hermes, never inside the home.

    (none)       open Hermes in this console
    status       where the home is, whether Linux shares it, what Ollama lacks
    available    exit 0 when Hermes is installed here (the menu asks)
    install      run the official installer, unattended, with the home here
                 and the code outside it; HERMES_HOME and HERMES_RUNTIME_DIR
                 are set for this user
    ollama       set, for this user, what Ollama must serve for Hermes (a
                 context of 65536, flash attention, an 8-bit cache); Ollama
                 has to be restarted afterwards
    -DryRun      with install or ollama: say what would run or be set
    -Notify      say how it went in a notification (the menu has no console)
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('open', 'status', 'available', 'install', 'ollama')][string]$Verb = 'open',
    [switch]$DryRun,
    [switch]$Notify
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\Hermes.psm1') -Force
[void](Import-VivacStrings (Read-VivacSettings)['language'])

# A line for the person: on the console, or as a card when the menu ran this.
function Say-Hermes([string]$Text) {
    if (-not $Notify) { $Text; return }
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    Import-Module (Join-Path $root 'lib\Toasts.psm1') -Force
    Show-VivacToast (T 'hermes.title') $Text 'vivac' '' '' $null
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds(500)
    $t.Add_Tick({ if (-not (& (Get-Module Toasts) { $script:Stack.Count })) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } })
    $t.Start()
    [Windows.Threading.Dispatcher]::Run()
}

function Show-Status {
    $s = Get-VivacHermesStatus
    $lines = New-Object System.Collections.Generic.List[string]
    if ($s.Exists) { $lines.Add((T 'hermes.status_home' @($s.Home))) } else { $lines.Add((T 'hermes.status_missing' @($s.Home))) }
    if ($s.Launcher) { $lines.Add((T 'hermes.status_launcher' @($s.Launcher))) } else { $lines.Add((T 'hermes.not_installed')) }
    if ($s.LinuxShared) { $lines.Add((T 'hermes.status_linux' @($s.LinuxSince))) } else { $lines.Add((T 'hermes.status_linux_none')) }
    if ($s.OllamaMissing.Count) {
        $lines.Add((T 'hermes.status_ollama_missing' @((@($s.OllamaMissing.Keys) -join ', '))))
    } else {
        $lines.Add((T 'hermes.status_ollama_ok' @((Get-VivacHermesOllamaEnv)['OLLAMA_CONTEXT_LENGTH'])))
    }
    Say-Hermes ($lines -join "`n")
}

# The official installer, unattended: the home here, the code and the tool
# store under %LOCALAPPDATA%\hermes. uv trusts the Windows certificate store
# (UV_NATIVE_TLS): an antivirus that inspects TLS puts its own root only there.
function Install-Hermes {
    $hermesHome = Get-VivacHermesHome
    $installDir = Get-VivacHermesInstallDir
    $runtime = Get-VivacHermesRuntimeDir
    $script = Join-Path ([IO.Path]::GetTempPath()) ('hermes-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    $command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$script`" -HermesHome `"$hermesHome`" -InstallDir `"$installDir`" -NonInteractive"
    if ($DryRun) {
        T 'hermes.would_set' @('HERMES_HOME', $hermesHome)
        T 'hermes.would_set' @('HERMES_RUNTIME_DIR', $runtime)
        T 'hermes.would_run' @("irm $(Get-VivacHermesInstaller) > $script; $command")
        return
    }
    foreach ($pair in @(@('HERMES_HOME', $hermesHome), @('HERMES_RUNTIME_DIR', $runtime))) {
        [Environment]::SetEnvironmentVariable($pair[0], $pair[1], 'User')
        Set-Item -Path ('Env:' + $pair[0]) -Value $pair[1]
        T 'hermes.set' @($pair[0], $pair[1])
    }
    $env:UV_NATIVE_TLS = '1'
    Invoke-RestMethod (Get-VivacHermesInstaller) -OutFile $script
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -HermesHome $hermesHome -InstallDir $installDir -NonInteractive
        $code = $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue
    }
    if ($code) { Say-Hermes (T 'hermes.install_failed' @($code)); exit 1 }
    Write-VivacHermesMarker $hermesHome @{ windows_home = $hermesHome; windows_shared = (Get-Date -Format 'yyyyMMdd-HHmmss') }
    Say-Hermes (T 'hermes.install_done' @($hermesHome))
}

function Set-OllamaForHermes {
    $wanted = Get-VivacHermesOllamaEnv
    foreach ($k in $wanted.Keys) {
        if ($DryRun) { T 'hermes.would_set' @($k, $wanted[$k]); continue }
        [Environment]::SetEnvironmentVariable($k, $wanted[$k], 'User')
        T 'hermes.set' @($k, $wanted[$k])
    }
    if (-not $DryRun) { Say-Hermes (T 'hermes.ollama_done') }
}

switch ($Verb) {
    'status' { Show-Status }
    'available' { if (Find-VivacHermes) { exit 0 } else { exit 1 } }
    'install' { Install-Hermes }
    'ollama' { Set-OllamaForHermes }
    'open' {
        $launcher = Find-VivacHermes
        if (-not $launcher) { Say-Hermes (T 'hermes.not_installed'); exit 1 }
        $env:HERMES_HOME = Get-VivacHermesHome
        & $launcher
        exit $LASTEXITCODE
    }
}
