# The phone: KDE Connect, as part of vivac (docs/bridge.md at the root of the
# product, "The phone"). KDE Connect for Windows answers on its command line,
# kdeconnect-cli.exe; vivac only asks it things, with a time limit, and every
# part of this hides itself when it is not installed.
#
#   bin/vivac-phone.ps1 -Status   the bar's poll: the reachable phones, as
#                                 JSON, also kept in phone.json for the menu
#   the menu's Phone category     ring, send a file, send the clipboard, pair
#
# Unlike Linux, the bar shows no battery: the Windows build ships no D-Bus
# client to read it with, and kdeconnect-cli does not print it.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Apps.psm1')

$script:Utf8 = New-Object Text.UTF8Encoding $false

# kdeconnect-cli.exe, or $null. VIVAC_KDECONNECT_CLI points the gates at a
# fake (a .ps1 is run through PowerShell); set and missing, it is missing.
function Get-VivacPhoneCli {
    if ($env:VIVAC_KDECONNECT_CLI) {
        if (Test-Path -LiteralPath $env:VIVAC_KDECONNECT_CLI) { return $env:VIVAC_KDECONNECT_CLI }
        return $null
    }
    Find-VivacApp 'kdeconnect'
}

# KDE Connect's own window, beside the command line: where pairing is done.
function Get-VivacPhoneApp {
    $cli = Get-VivacPhoneCli
    if (-not $cli) { return $null }
    $app = Join-Path (Split-Path -Parent $cli) 'kdeconnect-app.exe'
    if (Test-Path -LiteralPath $app) { return $app }
    $null
}

# One command-line argument, quoted the way the C runtime splits them.
function ConvertTo-VivacArgument([string]$Text) {
    if ($Text -and $Text -notmatch '[\s"]') { return $Text }
    '"' + ($Text -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Runs kdeconnect-cli with $Arguments: its exit code and what it printed, or
# $null when it is not installed. Killed after $TimeoutMs: a daemon gone wrong
# must not hold the bar or the menu.
function Invoke-VivacPhoneCli([string[]]$Arguments, [int]$TimeoutMs = 8000) {
    $cli = Get-VivacPhoneCli
    if (-not $cli) { return $null }
    $quoted = @($Arguments | ForEach-Object { ConvertTo-VivacArgument $_ }) -join ' '
    if ($cli -like '*.ps1') {
        $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $(ConvertTo-VivacArgument $cli) $quoted")
    } else {
        $psi = New-Object Diagnostics.ProcessStartInfo $cli, $quoted
    }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $script:Utf8
    try {
        $proc = [Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEndAsync()
        [void]$proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ Code = -1; Out = '' }
        }
        [pscustomobject]@{ Code = $proc.ExitCode; Out = [string]$out.Result }
    } catch {
        [pscustomobject]@{ Code = -1; Out = '' }
    }
}

# A device id names a D-Bus path on the other side: letters, digits, _ and -,
# and never a leading -, so it cannot pass for an option.
function Test-VivacPhoneId([string]$Id) { $Id -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' }

# The paired phones KDE Connect can reach now: id and name each.
function Get-VivacPhoneDevices {
    $r = Invoke-VivacPhoneCli @('--list-available', '--id-name-only')
    if (-not $r -or $r.Code -ne 0) { return @() }
    @(foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match '^(\S+) (.+)$' -and (Test-VivacPhoneId $Matches[1])) {
            [pscustomobject]@{ id = $Matches[1]; name = ($Matches[2] -replace '[\x00-\x1F]', ' ').Trim() }
        }
    })
}

function Get-VivacPhoneStatePath { Join-Path (Get-VivacPaths).State 'phone.json' }

# What the bar draws, $null without KDE Connect; written to phone.json too, so
# the menu knows the phones without asking (and waiting) itself.
function Get-VivacPhoneStatus {
    if (-not (Get-VivacPhoneCli)) {
        Remove-Item -LiteralPath (Get-VivacPhoneStatePath) -Force -ErrorAction SilentlyContinue
        return $null
    }
    $status = [ordered]@{ phones = @(Get-VivacPhoneDevices) }
    try {
        $state = [ordered]@{ time = (Get-Date).ToUniversalTime().ToString('o'); phones = $status.phones }
        Write-VivacFile -Path (Get-VivacPhoneStatePath) -Text (ConvertTo-Json -InputObject $state -Compress -Depth 4)
    } catch { }
    $status
}

# The phones the bar saw last, if it saw them in the last five minutes.
function Read-VivacPhoneState {
    $path = Get-VivacPhoneStatePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $s = [IO.File]::ReadAllText($path, $script:Utf8) | ConvertFrom-Json
        if (([DateTime]::UtcNow - ([DateTime]::Parse([string]$s.time)).ToUniversalTime()).TotalMinutes -gt 5) { return @() }
        @($s.phones | Where-Object { $_ -and (Test-VivacPhoneId ([string]$_.id)) })
    } catch { @() }
}

# The menu's Phone category: per phone, ring, a file and the clipboard; and
# always, while KDE Connect is installed, pairing. Nothing without it. Each
# entry is kind 'phone', target "<action>|<id>|<name>".
function Get-VivacPhoneMenuEntries([scriptblock]$NewEntry) {
    if (-not (Get-VivacPhoneCli)) { return @() }
    $phones = @(Read-VivacPhoneState)
    @(
        foreach ($p in $phones) {
            $tail = "|$($p.id)|$($p.name)"
            & $NewEntry 'phone' (T 'phone.ring') 'phone' "ring$tail" $false 0xEA8F ([string]$p.name)
            & $NewEntry 'phone' (T 'phone.send_file') 'phone' "send-file$tail" $false 0xE898 ([string]$p.name)
            & $NewEntry 'phone' (T 'phone.send_clip') 'phone' "send-clip$tail" $false 0xE8C8 ([string]$p.name)
        }
        & $NewEntry 'phone' (T 'phone.manage') 'phone' 'manage||' $false 0xE8EA ''
    )
}

Export-ModuleMember -Function *
