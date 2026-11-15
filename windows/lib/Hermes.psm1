# Hermes across the dual boot (docs/bridge.md at the product root): one Hermes
# Agent home for both halves. Windows owns the folder, on its own partition
# (%USERPROFILE%\.hermes, which Linux reaches through its mount of this
# partition as Users\<name>\.hermes). The shared root is not an option for
# it: Windows reaches that disk over 9P, where SQLite cannot lock a file.
# Code and tool store stay per side: the checkout under %LOCALAPPDATA%\hermes
# and the tool store beside it, never inside the home.
#
# This module only reads and writes; bin\vivac-hermes.ps1 acts.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')

$script:MarkerName = 'vivac-hermes.conf'
$script:Installer = 'https://hermes-agent.nousresearch.com/install.ps1'
# What Ollama must serve for Hermes to start (it refuses below 64,000 tokens
# of context) and what makes that much fit a 16 GB card: flash attention and
# an 8-bit key-value cache halve the memory of the context.
$script:OllamaEnv = [ordered]@{
    OLLAMA_CONTEXT_LENGTH  = '65536'
    OLLAMA_FLASH_ATTENTION = '1'
    OLLAMA_KV_CACHE_TYPE   = 'q8_0'
}

# The home: HERMES_HOME when set (the installer and hermes itself read it),
# otherwise .hermes in the profile, the same name Linux gives its own.
function Get-VivacHermesHome {
    if ($env:HERMES_HOME) { return $env:HERMES_HOME }
    $user = [Environment]::GetEnvironmentVariable('HERMES_HOME', 'User')
    if ($user) { return $user }
    Join-Path (Get-VivacPaths).Profile '.hermes'
}
function Get-VivacHermesInstallDir { Join-Path (Join-Path (Get-VivacPaths).LocalAppData 'hermes') 'hermes-agent' }
function Get-VivacHermesRuntimeDir { Join-Path (Join-Path (Get-VivacPaths).LocalAppData 'hermes') 'runtime' }
function Get-VivacHermesInstaller { $script:Installer }
function Get-VivacHermesOllamaEnv { $script:OllamaEnv }

# The hermes command: the launcher the installer staged into <home>in
# (hermes.exe; older installs left a hermes.cmd), or one already on the
# PATH. $null when neither is there.
function Find-VivacHermes([string]$Dir = (Get-VivacHermesHome)) {
    foreach ($name in 'hermes.exe', 'hermes.cmd') {
        $staged = Join-Path (Join-Path $Dir 'bin') $name
        if (Test-Path -LiteralPath $staged) { return $staged }
    }
    $cmd = Get-Command hermes -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $null
}

# The marker both sides write in the home: key=value, LF, no BOM, the same
# shape Linux's kv_get reads. windows_home and windows_shared are this side's,
# linux_home, linux_store and linux_shared the other's (linux_shared=none once
# it brought its home back).
function Get-VivacHermesMarkerPath([string]$Dir = (Get-VivacHermesHome)) { Join-Path $Dir $script:MarkerName }
function Read-VivacHermesMarker([string]$Dir = (Get-VivacHermesHome)) {
    (Read-VivacKeyValue (Get-VivacHermesMarkerPath $Dir)).Values
}
function Write-VivacHermesMarker([string]$Dir, [hashtable]$Pairs) {
    $path = Get-VivacHermesMarkerPath $Dir
    [void](New-Item -ItemType Directory -Force -Path $Dir)
    # One line per key, the other side's lines kept as they are (this is not
    # the settings file: it has no validation to go through).
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            $i = $line.IndexOf('=')
            if ($i -gt 0 -and $Pairs.ContainsKey($line.Substring(0, $i).Trim())) { continue }
            if ($line.Trim()) { $lines.Add($line.TrimEnd("`r")) }
        }
    }
    foreach ($k in $Pairs.Keys) { $lines.Add("$k=$([string]$Pairs[$k])") }
    Write-VivacFile -Path $path -Text (($lines -join "`n") + "`n")
}
function Test-VivacHermesLinuxShared([string]$Dir = (Get-VivacHermesHome)) {
    $m = Read-VivacHermesMarker $Dir
    [bool]($m.Contains('linux_shared') -and $m['linux_shared'] -and $m['linux_shared'] -ne 'none')
}

# The Ollama variables still missing at the user level, name=value.
function Get-VivacHermesOllamaMissing {
    $missing = [ordered]@{}
    foreach ($k in $script:OllamaEnv.Keys) {
        if ([Environment]::GetEnvironmentVariable($k, 'User') -ne $script:OllamaEnv[$k]) { $missing[$k] = $script:OllamaEnv[$k] }
    }
    $missing
}

# Everything status prints, in one object.
function Get-VivacHermesStatus([string]$Dir = (Get-VivacHermesHome)) {
    $marker = Read-VivacHermesMarker $Dir
    [pscustomobject]@{
        Home          = $Dir
        Exists        = [bool](Test-Path -LiteralPath $Dir -PathType Container)
        Launcher      = Find-VivacHermes $Dir
        LinuxShared   = Test-VivacHermesLinuxShared $Dir
        LinuxSince    = $(if ($marker.Contains('linux_shared')) { $marker['linux_shared'] } else { '' })
        WindowsSince  = $(if ($marker.Contains('windows_shared')) { $marker['windows_shared'] } else { '' })
        OllamaMissing = Get-VivacHermesOllamaMissing
    }
}

Export-ModuleMember -Function Get-VivacHermesHome, Get-VivacHermesInstallDir, Get-VivacHermesRuntimeDir,
Get-VivacHermesInstaller, Get-VivacHermesOllamaEnv, Find-VivacHermes, Get-VivacHermesMarkerPath,
Read-VivacHermesMarker, Write-VivacHermesMarker, Test-VivacHermesLinuxShared, Get-VivacHermesOllamaMissing,
Get-VivacHermesStatus
