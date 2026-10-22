# The shared library: palettes, settings, facts, rendering, i18n and atomic
# writes. Everything else in the repository imports this module and nothing
# else, so a rule written here holds for every caller.
#
# Windows PowerShell 5.1 is the floor on purpose: it ships with every
# Windows 11, so nothing here needs installing before it can run. That rules
# out ?:, ??, ConvertFrom-Json -AsHashtable and friends, and it means every
# .ps1 in the repository stays ASCII (5.1 reads a BOM-less file as ANSI).

Set-StrictMode -Version 2.0

$script:Root = Split-Path -Parent $PSScriptRoot
$script:Utf8 = New-Object System.Text.UTF8Encoding $false
$script:DefaultTheme = 'bad-romance'

# --------------------------------------------------------------------- paths

# Every location is derived from three roots, and each root can be redirected
# through the environment. The deploy regression points all three at a
# scratch directory, so a test can never write into the real profile.
function Get-VivacPaths {
    $vivacProfile = $env:VIVAC_PROFILE
    if (-not $vivacProfile) { $vivacProfile = $env:USERPROFILE }
    $roaming = $env:VIVAC_APPDATA
    if (-not $roaming) { $roaming = $env:APPDATA }
    $local = $env:VIVAC_LOCALAPPDATA
    if (-not $local) { $local = $env:LOCALAPPDATA }
    [pscustomobject]@{
        Repo         = $script:Root
        Profile      = $vivacProfile
        AppData      = $roaming
        LocalAppData = $local
        Config       = Join-Path $roaming 'vivac'
        State        = Join-Path $local 'vivac'
        Settings     = Join-Path (Join-Path $roaming 'vivac') 'settings'
        Facts        = Join-Path (Join-Path $roaming 'vivac') 'hardware-facts'
        FactsOverride = Join-Path (Join-Path $roaming 'vivac') 'hardware-facts.override'
        Backups      = Join-Path (Join-Path $local 'vivac') 'backups'
        Manifest     = Join-Path (Join-Path $local 'vivac') 'deploy-manifest.tsv'
        Wallpapers   = Join-Path (Join-Path $local 'vivac') 'wallpapers'
        SharedPending = Join-Path (Join-Path $local 'vivac') 'shared-pending'
        SharedLock   = Join-Path (Join-Path $local 'vivac') 'shared-sync.lock'
        LockMarker   = Join-Path (Join-Path $local 'vivac') 'session-locked'
        SharedDeferred = Join-Path (Join-Path $local 'vivac') 'shared-apply-pending'
        SharedLog    = Join-Path (Join-Path $local 'vivac') 'shared-sync.log'
        SharedPendingPulls = Join-Path (Join-Path $local 'vivac') 'shared-pending-pulls'
    }
}

# Where each package lands. A package is a directory under dotfiles/ (themed,
# committed), render/ (per machine, never committed) or static/ (copied as
# is); its files are placed under the root named here, keeping their relative
# paths. The terminal is the one surface that is merged rather than placed:
# Windows Terminal keeps a single settings file the user also edits.
function Get-VivacTargetRoot([string]$Package) {
    $p = Get-VivacPaths
    switch ($Package) {
        'glazewm' { return (Join-Path $p.Profile '.glzr\glazewm') }
        'zebar'   { return (Join-Path $p.Profile '.glzr\zebar') }
        'flow'    { return (Join-Path $p.AppData 'FlowLauncher\Themes') }
        'nvim'    { return (Join-Path $p.LocalAppData 'nvim') }
        default   { throw "vivac: no target root for package '$Package'" }
    }
}

# The pipe the resident host listens on. Pipe names are machine-wide, so the
# account name keeps two signed-in users from colliding.
function Get-VivacPipeName {
    'vivac-' + (($env:USERNAME -replace '[^A-Za-z0-9_.-]', '_').ToLowerInvariant())
}

function Get-VivacTerminalSettingsPath {
    $p = Get-VivacPaths
    Join-Path $p.LocalAppData 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
}

# ------------------------------------------------------------- key=value I/O

# The key=value format every data file here shares: '#' starts a comment,
# blank lines are ignored, the first '=' splits, and a later key wins. A
# comment of the form '# @name: value' is metadata, kept apart from values.
function Read-VivacKeyValue([string]$Path) {
    $values = [ordered]@{}
    $meta = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Values = $values; Meta = $meta; Exists = $false }
    }
    foreach ($line in [IO.File]::ReadAllLines($Path, $script:Utf8)) {
        if ($line -match '^\s*#\s*@([a-z_]+):\s*(.*?)\s*$') {
            $meta[$Matches[1]] = $Matches[2]
            continue
        }
        if ($line -match '^\s*(#|$)') { continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { throw "vivac: ${Path}: not key=value: $line" }
        $values[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
    [pscustomobject]@{ Values = $values; Meta = $meta; Exists = $true }
}

# Write one key, keeping every other line (comments included) as it was.
function Set-VivacKeyValue([string]$Path, [string]$Key, [string]$Value) {
    if ($Value -match "[`r`n]") { throw "vivac: a value cannot span lines" }
    $lines = New-Object System.Collections.Generic.List[string]
    $found = $false
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path, $script:Utf8)) {
            if ($line -match "^\s*$([regex]::Escape($Key))\s*=") {
                if (-not $found) { $lines.Add("$Key=$Value") }
                $found = $true
            } else {
                $lines.Add($line)
            }
        }
    }
    if (-not $found) { $lines.Add("$Key=$Value") }
    Write-VivacFile -Path $Path -Text (($lines -join "`n") + "`n")
}

# -------------------------------------------------------------------- writes

# Atomic write, UTF-8 without BOM, LF endings left exactly as given. The
# scratch file sits beside the target so the final move is a rename on the
# same volume: a reader (GlazeWM watches its config) never sees half a file.
function Write-VivacFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $scratch = "$Path.vivac-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [IO.File]::WriteAllText($scratch, $Text, $script:Utf8)
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($scratch, $Path, [NullString]::Value)
    } else {
        [IO.File]::Move($scratch, $Path)
    }
}

function Read-VivacText([string]$Path) {
    [IO.File]::ReadAllText($Path, $script:Utf8)
}

function Get-VivacHash([string]$Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# ------------------------------------------------------------------- palettes

$script:TokenNames = @(
    'COLOR_BG', 'COLOR_FG', 'COLOR_FG_DIM', 'COLOR_SURFACE', 'COLOR_SURFACE_ALT',
    'COLOR_ACCENT', 'COLOR_MUTED', 'COLOR_URGENT', 'COLOR_INFO', 'COLOR_OK',
    'COLOR_BORDER_INACTIVE', 'TERMINAL_BG', 'TERMINAL_FG')

function Get-VivacTokenNames { $script:TokenNames }
function Get-VivacDefaultTheme { $script:DefaultTheme }

function Get-VivacThemePath([string]$Name) {
    if ($Name -eq $script:DefaultTheme) { return (Join-Path $script:Root 'data\theme.conf') }
    if ($Name -notmatch '^[a-z0-9][a-z0-9-]*$') { throw "vivac: not a theme name: '$Name'" }
    Join-Path $script:Root "data\themes\$Name.conf"
}

# The catalogue is the directory itself, the default first: a picker that kept
# its own list would drift from it.
function Get-VivacCatalogue {
    $names = @($script:DefaultTheme)
    $names += Get-ChildItem -LiteralPath (Join-Path $script:Root 'data\themes') -Filter '*.conf' |
        ForEach-Object { $_.BaseName } | Sort-Object
    $names
}

# A palette is exactly the thirteen tokens, each bare upper-case hex. Anything
# else is refused here so no template ever has to guess.
function Read-VivacTheme([string]$Name) {
    $path = Get-VivacThemePath $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "vivac: no theme named '$Name'" }
    $kv = Read-VivacKeyValue $path
    foreach ($key in $kv.Values.Keys) {
        if ($script:TokenNames -notcontains $key) { throw "vivac: ${path}: unknown token $key" }
        if ($kv.Values[$key] -cnotmatch '^[0-9A-F]{6}$') {
            throw "vivac: ${path}: $key is not bare upper-case 6-digit hex: '$($kv.Values[$key])'"
        }
    }
    foreach ($key in $script:TokenNames) {
        if (-not $kv.Values.Contains($key)) { throw "vivac: ${path}: missing token $key" }
    }
    $title = $Name
    if ($kv.Meta.Contains('title')) { $title = $kv.Meta['title'] }
    $essence = ''
    if ($kv.Meta.Contains('essence')) { $essence = $kv.Meta['essence'] }
    [pscustomobject]@{
        Name = $Name; Path = $path; Tokens = $kv.Values; Meta = $kv.Meta
        Title = $title; Essence = $essence
    }
}

# ------------------------------------------------------------------ settings

# Choices, not detections. A missing file or key means these defaults.
$script:SettingDefaults = [ordered]@{
    language         = 'es'
    theme            = 'bad-romance'
    mod              = 'lwin'
    weather_location = 'auto'
    shared_settings  = 'none'
}
$script:SettingRules = @{
    language         = '^(es|en)$'
    mod              = '^(alt|lwin)$'
    # auto (Zebar estimates the place from the public IP), off, or lat,lon.
    weather_location = '^(auto|off|-?\d{1,2}(\.\d+)?,-?\d{1,3}(\.\d+)?)$'
    # none, or the file shared with another OS: an absolute path (C:\x or
    # C:/x) or one under the profile (~\x, ~/x). No characters Windows refuses
    # in a name.
    shared_settings  = '^(none|([A-Za-z]:[\\/]|~[\\/])[^\x00-\x1f"<>|*?]+)$'
}

function Read-VivacSettings {
    $kv = Read-VivacKeyValue (Get-VivacPaths).Settings
    $settings = [ordered]@{}
    foreach ($key in $script:SettingDefaults.Keys) {
        $value = $script:SettingDefaults[$key]
        if ($kv.Values.Contains($key) -and $kv.Values[$key]) { $value = $kv.Values[$key] }
        $settings[$key] = $value
    }
    $settings
}

# Throws unless Value is acceptable for Key: the one set of validators every
# path into the settings file uses, local choices and shared ones alike.
function Assert-VivacSettingValid([string]$Key, [string]$Value) {
    if (-not $script:SettingDefaults.Contains($Key)) { throw "vivac: unknown setting '$Key'" }
    if ($Key -eq 'theme') {
        if ((Get-VivacCatalogue) -notcontains $Value) { throw "vivac: no theme named '$Value'" }
    } elseif ($Value -notmatch $script:SettingRules[$Key]) {
        throw "vivac: '$Value' is not a valid value for $Key"
    }
}

# The one writer of the settings file. A value is validated before it lands,
# so every reader can trust what it reads. A shared key (see below) is also
# sent to the shared file when one is configured.
function Set-VivacSetting([string]$Key, [string]$Value) {
    # A shared key is lowercase on both sides (Windows matching is
    # case-insensitive, Linux's is not): normalised here, the local value and
    # the shared one are the same string and the pull never "corrects" it.
    if ($script:SharedKeys -contains $Key) { $Value = $Value.ToLowerInvariant() }
    Write-VivacLocalSetting $Key $Value
    if ($script:SharedKeys -contains $Key) { Send-VivacSharedKey $Key $Value }
}

function Write-VivacLocalSetting([string]$Key, [string]$Value) {
    Assert-VivacSettingValid $Key $Value
    Set-VivacKeyValue -Path (Get-VivacPaths).Settings -Key $Key -Value $Value
}

# ------------------------------------------------------------ shared settings

# An optional flat key=value file another OS also reads (the Linux side of
# vivac keeps the same contract). Only these keys travel; mod and the rest
# are local, and any other key in the file belongs to the other OS: it is
# ignored on read and kept on write. The file is handled as bytes (Latin-1
# keeps every byte), so what this side did not write comes back unchanged.
$script:SharedKeys = @('theme', 'weather_location', 'language')
$script:Latin1 = [Text.Encoding]::GetEncoding(28591)
# The one call that swaps the new content in; a seam so a test can make it fail.
$script:ReplaceFile = { param($Scratch, $Destination, $Backup) [IO.File]::Replace($Scratch, $Destination, $Backup) }
# A share that has no ReplaceFileW (a \\wsl.localhost path, such as a WSL disk shared with Linux) still
# renames over a file atomically, which is what the Linux side does with mv.
if (-not ('VivacRename' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class VivacRename {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool MoveFileEx(string from, string to, int flags);
    // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
    public static void Over(string from, string to) {
        if (!MoveFileEx(from, to, 0x1 | 0x8)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
}
function Test-VivacNotSupported($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    ($e.HResult -band 0xFFFF) -eq 50
}

function Get-VivacSharedKeys { $script:SharedKeys }

# The Linux side's own shapes for the shared keys (settings_valid in its
# lib/settings.sh), case-sensitive. A value that passes the Windows checks
# but not these must not reach a file Linux reads.
$script:LinuxShapes = @{
    theme            = '^[a-z][a-z0-9-]*\z'
    weather_location = '^[A-Za-z0-9_.,+-]+\z'
    language         = '^(auto|[a-z]{2,3})\z'
}
function Test-VivacSharedValueValid([string]$Key, [string]$Value) {
    $script:LinuxShapes.ContainsKey($Key) -and $Value -cmatch $script:LinuxShapes[$Key]
}

# The shared file's path when sharing is configured, otherwise $null: no
# sharing is the normal case, not an error.
function Get-VivacSharedPath {
    $raw = (Read-VivacSettings)['shared_settings']
    if ($raw -eq 'none' -or $raw -notmatch $script:SettingRules['shared_settings']) { return $null }
    if ($raw -match '^~[\\/]') {
        $raw = Join-Path (Get-VivacPaths).Profile ($raw.Substring(2) -replace '/', '\')
    }
    $raw
}

# Lines of a shared file as another OS wrote it: a BOM and CR dropped, split
# on LF only. A missing final newline is tolerated; a missing file has none.
function Read-VivacSharedLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $text = $script:Latin1.GetString([IO.File]::ReadAllBytes($Path))
    if ($text.StartsWith("$([char]0xEF)$([char]0xBB)$([char]0xBF)")) { $text = $text.Substring(3) }
    $text = $text -replace "[\r\x00]", ''
    if ($text -eq '') { return @() }
    $lines = $text.Split("`n")
    if ($lines[$lines.Count - 1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    @($lines)
}

# Set one key of the shared file in place. Other lines and their order stay;
# the new line is LF. A value already there writes nothing, and a missing
# folder (a share that is away) is never created.
function Write-VivacSharedKey([string]$Path, [string]$Key, [string]$Value) {
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $Path) -PathType Container)) { return }
    $lines = @(Read-VivacSharedLines $Path)
    $hits = @($lines | Where-Object { $_.StartsWith("$Key=", [StringComparison]::Ordinal) })
    if ($hits.Count -eq 1 -and $hits[0] -ceq "$Key=$Value") { return }
    $out = New-Object System.Collections.Generic.List[string]
    $placed = $false
    foreach ($line in $lines) {
        if ($line.StartsWith("$Key=", [StringComparison]::Ordinal)) {
            if (-not $placed) { $out.Add("$Key=$Value") }
            $placed = $true
        } else { $out.Add($line) }
    }
    if (-not $placed) { $out.Add("$Key=$Value") }
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $scratch = "$Path.vivac-$tag"
    $backup = "$Path.vivac-bak-$tag"
    try {
        [IO.File]::WriteAllBytes($scratch, $script:Latin1.GetBytes((($out -join "`n") + "`n")))
        if (Test-Path -LiteralPath $Path) {
            try { & $script:ReplaceFile $scratch $Path $backup }
            catch {
                # ERROR_NOT_SUPPORTED: the share cannot replace, so nothing was
                # touched; rename the scratch over the file instead.
                if ((Test-VivacNotSupported $_) -and (Test-Path -LiteralPath $Path) -and (Test-Path -LiteralPath $scratch)) {
                    [VivacRename]::Over($scratch, $Path)
                    return
                }
                # ReplaceFileW can fail after it has already taken the
                # destination away (error 1177). The shared file is the other
                # OS's too: put the old content back, or failing that the new,
                # before reporting the failure.
                if (-not (Test-Path -LiteralPath $Path)) {
                    if (Test-Path -LiteralPath $backup) { [IO.File]::Move($backup, $Path) }
                    elseif (Test-Path -LiteralPath $scratch) { [IO.File]::Move($scratch, $Path) }
                }
                throw
            }
        } else { [IO.File]::Move($scratch, $Path) }
    } finally {
        # Only once the destination is known to exist.
        if (Test-Path -LiteralPath $Path) {
            foreach ($leftover in $scratch, $backup) {
                if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

# Changes the shared file could not take yet, one key per line in the state
# directory. The pull sends the local value of a pending key instead of
# taking the other OS's older one.
function Get-VivacPendingKeys {
    $p = (Get-VivacPaths).SharedPending
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @([IO.File]::ReadAllLines($p) | Where-Object { $_ })
}
function Test-VivacPending([string]$Key) { (Get-VivacPendingKeys) -contains $Key }
function Add-VivacPending([string]$Key) {
    if (Test-VivacPending $Key) { return }
    $p = (Get-VivacPaths).SharedPending
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    [IO.File]::AppendAllText($p, "$Key`n")
}
function Remove-VivacPending([string]$Key) {
    Clear-VivacPendingAge $Key
    $keep = @(Get-VivacPendingKeys | Where-Object { $_ -ne $Key })
    $p = (Get-VivacPaths).SharedPending
    if (-not (Test-Path -LiteralPath $p)) { return }
    $text = ''
    foreach ($k in $keep) { $text += "$k`n" }
    Write-VivacFile -Path $p -Text $text
}

# The pull runs in a hidden process nobody reads, so what goes wrong in it is
# written here: one line per event, in the state directory.
function Write-VivacSharedLog([string]$Text) {
    try {
        $log = (Get-VivacPaths).SharedLog
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
        [IO.File]::AppendAllText($log, ('{0}  {1}{2}' -f (Get-Date -Format s), $Text, "`n"))
    } catch { }
}

# How many pulls in a row ended with a key still pending (one "key count" line
# each). From PendingWarnAfter on, every pull says so, once per key.
$script:PendingWarnAfter = 3
function Read-VivacPendingAges {
    $ages = [ordered]@{}
    $p = (Get-VivacPaths).SharedPendingPulls
    if (Test-Path -LiteralPath $p) {
        foreach ($line in [IO.File]::ReadAllLines($p)) {
            if ($line -match '^(\S+) (\d+)$') { $ages[$Matches[1]] = [int]$Matches[2] }
        }
    }
    $ages
}
function Write-VivacPendingAges($Ages) {
    $text = ''
    foreach ($k in $Ages.Keys) { $text += "$k $($Ages[$k])`n" }
    Write-VivacFile -Path (Get-VivacPaths).SharedPendingPulls -Text $text
}
function Clear-VivacPendingAge([string]$Key) {
    $ages = Read-VivacPendingAges
    if ($ages.Contains($Key)) { $ages.Remove($Key); Write-VivacPendingAges $ages }
}
function Step-VivacPendingAges {
    $ages = Read-VivacPendingAges
    $pendingNow = @(Get-VivacPendingKeys)
    foreach ($k in @($ages.Keys)) { if ($pendingNow -notcontains $k) { $ages.Remove($k) } }
    foreach ($k in $pendingNow) {
        $n = 1
        if ($ages.Contains($k)) { $n = $ages[$k] + 1 }
        $ages[$k] = $n
        if ($n -ge $script:PendingWarnAfter) {
            $msg = "$k has stayed pending for $n pulls: the shared file has not taken the local value yet"
            Write-Warning "sync-shared-settings: $msg"
            Write-VivacSharedLog $msg
        }
    }
    Write-VivacPendingAges $ages
}

# Take the shared lock (an exclusive handle on a file in the state
# directory, so a crashed holder frees it), waiting up to Seconds. $null when
# it stayed busy.
function Enter-VivacSharedLock([double]$Seconds) {
    $path = (Get-VivacPaths).SharedLock
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $limit = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        try { return New-Object IO.FileStream($path, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $limit) { return $null }
            Start-Sleep -Milliseconds 100
        }
    }
}

# The change path for a shared key. A shared file that cannot be written costs
# a warning, never the local change, and the key stays pending until a pull
# can send it. The warning comes once per key.
function Send-VivacSharedKey([string]$Key, [string]$Value) {
    $shared = Get-VivacSharedPath
    if (-not $shared) { return }
    if (-not (Test-VivacSharedValueValid $Key $Value)) {
        Write-Warning "settings: '$Value' is not a valid $Key for the shared file (the other OS would refuse it); $Key stays local"
        return
    }
    $folder = Split-Path -Parent $shared
    $problem = $null
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        $problem = "the shared folder $folder is not there; $Key stays local and is sent when it is"
    } else {
        $wait = 10
        if ($env:VIVAC_SETTINGS_LOCK_WAIT) { $wait = [double]$env:VIVAC_SETTINGS_LOCK_WAIT }
        $lock = Enter-VivacSharedLock $wait
        if (-not $lock) { $problem = "the shared file $shared is busy; $Key stays local and is sent next time" }
        else {
            try {
                Write-VivacSharedKey $shared $Key $Value
                Remove-VivacPending $Key
            } catch { $problem = "could not update the shared file $shared; $Key stays local and is sent next time" }
            finally { $lock.Dispose() }
        }
    }
    if ($problem) {
        if (-not (Test-VivacPending $Key)) { Write-Warning "settings: $problem" }
        Add-VivacPending $Key
    }
}

# Sign-in: bring the other OS's choices in. Returns the keys it changed.
# What the change path could not send (a share that was away) goes out first,
# from the local value, and a key whose push failed keeps that value whatever
# the share says. Then each shared key found in the file is validated like a
# local choice and applied; one that fails is reported and skipped without
# stopping the rest. Nothing is written back to the shared file for what was
# taken from it. No sharing, no file, or a lock that stays busy is silence.
function Invoke-VivacSharedPull([double]$LockWaitSeconds = -1) {
    $shared = Get-VivacSharedPath
    if (-not $shared) { return @() }
    if ($LockWaitSeconds -lt 0) {
        $LockWaitSeconds = 60
        if ($env:VIVAC_SYNC_LOCK_WAIT) { $LockWaitSeconds = [double]$env:VIVAC_SYNC_LOCK_WAIT }
    }
    $lock = Enter-VivacSharedLock $LockWaitSeconds
    if (-not $lock) { return @() }
    $changed = New-Object System.Collections.Generic.List[string]
    try {
        $local = Read-VivacSettings
        if (Test-Path -LiteralPath (Split-Path -Parent $shared) -PathType Container) {
            foreach ($key in @(Get-VivacPendingKeys)) {
                if ($script:SharedKeys -notcontains $key) { continue }
                try { Write-VivacSharedKey $shared $key $local[$key]; Remove-VivacPending $key }
                catch { Write-VivacSharedLog "could not send $key to ${shared}: $($_.Exception.Message); it stays pending" }
            }
        }
        Step-VivacPendingAges
        if (-not (Test-Path -LiteralPath $shared -PathType Leaf)) { return @() }
        $incoming = @{}
        try {
            foreach ($line in (Read-VivacSharedLines $shared)) {
                foreach ($key in $script:SharedKeys) {
                    if ($line.StartsWith("$key=", [StringComparison]::Ordinal)) { $incoming[$key] = $line.Substring($key.Length + 1) }
                }
            }
        } catch { Write-VivacSharedLog "could not read ${shared}: $($_.Exception.Message)"; return @() }
        foreach ($key in $script:SharedKeys) {
            if (-not $incoming.ContainsKey($key) -or (Test-VivacPending $key)) { continue }
            $value = $incoming[$key]
            try { Assert-VivacSettingValid $key $value }
            catch {
                Write-Warning "sync-shared-settings: ignoring $key in ${shared}: '$value' is not valid"
                Write-VivacSharedLog "ignoring $key in ${shared}: '$value' is not valid"
                continue
            }
            if ($value -ceq $local[$key]) { continue }
            Write-VivacLocalSetting $key $value
            $changed.Add($key)
        }
    } finally { $lock.Dispose() }
    $changed.ToArray()
}

# While the resident host holds a lock (the cover and greeter it puts up at an
# automatic sign-in, kind 'start', or the lock screen, kind 'lock') it leaves
# "PID kind" here. Anything that would restart the host, a theme applied from
# the shared file for one, reads it first. A marker of a dead process is stale.
# None of the three throws: the marker is a courtesy to the pull, and the
# lock it describes must run the same when the state directory cannot be
# written (disk full, an antivirus lock, a bad ACL). A failure is logged.
# The marker carries its writer's start time, so a PID the system has given to
# another process since reads as stale. The time of another process comes from
# WMI, which also answers for one above our integrity level (the host's), and
# is bounded to 2 seconds: this runs next to the greeter. The query is a seam
# so a test can make it fail.
$script:QueryProcessStart = {
    param($Id)
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -OperationTimeoutSec 2 -ErrorAction Stop
    if ($p) { $p.CreationDate.ToFileTimeUtc() }
}
# $null when WMI threw, timed out or had no answer: unknown, not "gone".
function Get-VivacProcessStart([int]$Id) {
    try { $t = & $script:QueryProcessStart $Id; if ($null -ne $t) { return [long]$t } } catch { }
    $null
}
function Set-VivacLockMarker([string]$Kind) {
    try {
        $start = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()
        Write-VivacFile -Path (Get-VivacPaths).LockMarker -Text "$PID $Kind $start`n"
        $true
    } catch {
        Write-VivacSharedLog "could not write the lock marker: $($_.Exception.Message)"
        $false
    }
}
function Get-VivacLockMarker {
    try {
        $p = (Get-VivacPaths).LockMarker
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $text = ([IO.File]::ReadAllText($p)).Trim()
        if ($text -notmatch '^(\d+) (start|lock) (\d+)$') { return $null }
        $id = [int]$Matches[1]
        $kind = $Matches[2]
        $wrote = [long]$Matches[3]
        # Two seconds of slack: the creation time is rounded differently by
        # the two sources. Our own start time needs no WMI; another process
        # must be running, and only a start time that WMI actually gives and
        # that differs makes it stale: no answer is "unknown", so live.
        if ($id -eq $PID) {
            $now = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()
        } else {
            if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { return $null }
            $now = Get-VivacProcessStart $id
        }
        if ($null -ne $now -and [Math]::Abs($now - $wrote) -gt 20000000) { return $null }
        [pscustomobject]@{ Pid = $id; Kind = $kind }
    } catch { $null }
}
# Only the process that wrote the marker takes it down.
function Clear-VivacLockMarker {
    try {
        $m = Get-VivacLockMarker
        if ($m -and $m.Pid -ne $PID) { return }
        Remove-Item -LiteralPath (Get-VivacPaths).LockMarker -Force -ErrorAction SilentlyContinue
    } catch { Write-VivacSharedLog "could not clear the lock marker: $($_.Exception.Message)" }
}

# A host started without -LockAtStart holds no lock: whatever marker is there
# is left over (power loss in the greeter, a killed host) and goes, whoever
# wrote it. Never throws.
function Reset-VivacLockMarker {
    try { Remove-Item -LiteralPath (Get-VivacPaths).LockMarker -Force -ErrorAction SilentlyContinue }
    catch { Write-VivacSharedLog "could not reset the lock marker: $($_.Exception.Message)" }
}

# Run Body (the lock) with the marker held: marked here unless a marker is
# already held (the start-up cover's), and let go afterwards however Body ends.
# Body runs whether or not the marker could be written.
function Invoke-VivacWithLockMarker([string]$Kind, [scriptblock]$Body) {
    $marked = $false
    if (-not (Get-VivacLockMarker)) { $marked = Set-VivacLockMarker $Kind }
    try { & $Body } finally { if ($marked) { Clear-VivacLockMarker } }
}

# Shared changes that need a desktop reload (theme, location) and arrived while
# the session was locked: applied by the first pull after the unlock.
function Get-VivacDeferredKeys {
    $p = (Get-VivacPaths).SharedDeferred
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    @([IO.File]::ReadAllLines($p) | Where-Object { $_ })
}
function Set-VivacDeferredKeys([string[]]$Keys) {
    $p = (Get-VivacPaths).SharedDeferred
    if (-not $Keys) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; return }
    $text = ''
    foreach ($k in $Keys) { $text += "$k`n" }
    Write-VivacFile -Path $p -Text $text
}

# Start the sign-in pull in a process of its own, hidden, so the caller (the
# resident host) never waits on a share that may be away. Nothing starts when
# sharing is off.
function Start-VivacSharedSync {
    if (-not (Get-VivacSharedPath)) { return $null }
    $script = Join-Path $script:Root 'scripts\sync-shared-settings.ps1'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-Pull', '-WaitForShare', '90')
}

# ---------------------------------------------------------------------- facts

# Facts describe what the machine is. The detected file is written by
# scripts/hardware-facts.ps1; the override file, if present, wins key by key.
function Read-VivacFacts([string[]]$Paths) {
    if (-not $Paths) {
        $p = Get-VivacPaths
        $Paths = @($p.Facts, $p.FactsOverride)
    }
    $facts = [ordered]@{}
    $any = $false
    foreach ($path in $Paths) {
        $kv = Read-VivacKeyValue $path
        if (-not $kv.Exists) { continue }
        $any = $true
        foreach ($key in $kv.Values.Keys) { $facts[$key] = $kv.Values[$key] }
    }
    if (-not $any) { return $null }
    $facts
}

# Predicate grammar, shared with the source repository: key=value, key!=value,
# key~word (word in a space-separated list), joined by && (binding tighter)
# and ||. Unknown keys are an error, never false.
function Test-VivacPredicate([string]$Predicate, $Facts) {
    if (-not $Predicate.Trim()) { return $true }
    foreach ($alternative in ($Predicate -split '\|\|')) {
        $all = $true
        foreach ($term in ($alternative -split '&&')) {
            $term = $term.Trim()
            if ($term -notmatch '^([a-z_][a-z0-9_]*)(!=|=|~)([A-Za-z0-9_.:-]+)$') {
                throw "vivac: bad predicate term '$term'"
            }
            $key = $Matches[1]; $op = $Matches[2]; $want = $Matches[3]
            if (-not $Facts.Contains($key)) { throw "vivac: predicate names unknown fact '$key'" }
            $have = [string]$Facts[$key]
            $holds = switch ($op) {
                '='  { $have -eq $want }
                '!=' { $have -ne $want }
                '~'  { ($have -split '\s+') -contains $want }
            }
            if (-not $holds) { $all = $false; break }
        }
        if ($all) { return $true }
    }
    $false
}

# ------------------------------------------------------------------ rendering

function ConvertTo-VivacScaled([string]$Hex, [int]$Percent) {
    $out = ''
    foreach ($i in 0, 2, 4) {
        $channel = [Convert]::ToInt32($Hex.Substring($i, 2), 16)
        $out += '{0:X2}' -f [int][Math]::Floor($channel * $Percent / 100)
    }
    $out
}

# Filters, as in the source: lower, upper, rgb (a decimal triplet for rgba()),
# and three derived shades that darken toward black without adding a colour
# to the palette. A filter that does not apply to a value is an error.
function Invoke-VivacFilter([string]$Value, [string]$Filter, [string]$Name) {
    if (-not $Filter) { return $Value }
    $isHex = $Value -cmatch '^[0-9A-F]{6}$'
    switch ($Filter) {
        'lower' { return $Value.ToLowerInvariant() }
        'upper' { return $Value.ToUpperInvariant() }
        'json'  { return ($Value -replace '\\', '\\' -replace '"', '\"') }
    }
    if (-not $isHex) { throw "vivac: filter '$Filter' needs a colour, @$Name@ is '$Value'" }
    switch ($Filter) {
        'rgb'    { return ('{0}, {1}, {2}' -f [Convert]::ToInt32($Value.Substring(0, 2), 16), [Convert]::ToInt32($Value.Substring(2, 2), 16), [Convert]::ToInt32($Value.Substring(4, 2), 16)) }
        'dark'   { return (ConvertTo-VivacScaled $Value 70) }
        'darker' { return (ConvertTo-VivacScaled $Value 45) }
        'dim'    { return (ConvertTo-VivacScaled $Value 78) }
        'bgr'    { return ($Value.Substring(4, 2) + $Value.Substring(2, 2) + $Value.Substring(0, 2)) }
    }
    throw "vivac: unknown filter '$Filter'"
}

# Substitute @NAME@ and @NAME:filter@. An unknown token is an error: a
# placeholder silently rendered as nothing would ship a broken file.
function Expand-VivacString([string]$Text, $Tokens) {
    $evaluator = {
        param($m)
        $name = $m.Groups[1].Value
        if (-not $Tokens.Contains($name)) { throw "vivac: unknown token @$name@" }
        Invoke-VivacFilter -Value ([string]$Tokens[$name]) -Filter $m.Groups[3].Value -Name $name
    }
    [regex]::Replace($Text, '@([A-Z][A-Z0-9_]*)(:([a-z]+))?@', $evaluator)
}

# Render a template line by line. A line may start with a guard, @?pred@,
# kept (without the guard) when the predicate holds over the facts. A guard in
# a render without facts is an error, so a themed template can never come to
# depend on the machine it was rendered on.
function Expand-VivacTemplate([string]$Text, $Tokens, $Facts) {
    $out = New-Object System.Text.StringBuilder
    $lineNo = 0
    $lines = $Text -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNo++
        if ($line -match '^@\?([^@]*)@(.*)$') {
            if ($null -eq $Facts) { throw "vivac: line ${lineNo}: guard used without hardware facts" }
            if (-not (Test-VivacPredicate $Matches[1] $Facts)) { continue }
            $line = $Matches[2]
        }
        try {
            $rendered = Expand-VivacString $line $Tokens
        } catch {
            throw "vivac: line ${lineNo}: $($_.Exception.Message)"
        }
        [void]$out.Append($rendered)
        if ($i -lt $lines.Count - 1) { [void]$out.Append("`n") }
    }
    $out.ToString()
}

# The token set a render sees: the palette, the theme's own words, and for a
# per-machine render the settings (SET_*), the facts (FACT_*) and the paths a
# deployed file must point back to (PATH_*).
function Get-VivacTokens($Theme, $Settings, $Facts) {
    $tokens = [ordered]@{}
    foreach ($key in $Theme.Tokens.Keys) { $tokens[$key] = $Theme.Tokens[$key] }
    $tokens['THEME_NAME'] = $Theme.Name
    $tokens['THEME_TITLE'] = $Theme.Title
    $tokens['THEME_ESSENCE'] = $Theme.Essence
    if ($Settings) {
        foreach ($key in $Settings.Keys) { $tokens['SET_' + $key.ToUpperInvariant()] = $Settings[$key] }
        $tokens['PATH_REPO'] = $script:Root
    }
    if ($Facts) {
        foreach ($key in $Facts.Keys) { $tokens['FACT_' + $key.ToUpperInvariant()] = $Facts[$key] }
    }
    $tokens
}

# ----------------------------------------------------------------------- i18n

# Strings live in i18n/<lang>.conf. A key missing from the chosen language
# falls back to English marked [en]; a key missing from English is a bug and
# comes back as the key itself in brackets so it is seen, not hidden.
function Import-VivacStrings([string]$Language) {
    $en = (Read-VivacKeyValue (Join-Path $script:Root 'i18n\en.conf')).Values
    $chosen = $en
    if ($Language -and $Language -ne 'en') {
        $chosen = (Read-VivacKeyValue (Join-Path $script:Root "i18n\$Language.conf")).Values
    }
    $table = @{}
    foreach ($key in $en.Keys) {
        if ($chosen.Contains($key)) { $table[$key] = $chosen[$key] } else { $table[$key] = '[en] ' + $en[$key] }
    }
    $script:Strings = $table
    $table
}

function Get-VivacString([string]$Key, [object[]]$Arguments) {
    if (-not (Get-Variable -Scope Script -Name Strings -ErrorAction SilentlyContinue) -or $null -eq $script:Strings) {
        [void](Import-VivacStrings (Read-VivacSettings)['language'])
    }
    if (-not $script:Strings.ContainsKey($Key)) { return "[$Key]" }
    $text = $script:Strings[$Key]
    if ($Arguments) {
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            $text = $text.Replace('{' + ($i + 1) + '}', [string]$Arguments[$i])
        }
    }
    $text -replace '\\n', "`n"
}
Set-Alias -Name T -Value Get-VivacString

# --------------------------------------------------------------- help registry

# One row per key the help pane describes:
#   bind_id  pane  action_type  action_value  label_key
# bind_id spells the modifier as MOD; the pane prints the real one.
function Read-VivacHelpRegistry {
    $rows = @()
    $path = Join-Path $script:Root 'data\help-registry.tsv'
    foreach ($line in [IO.File]::ReadAllLines($path, $script:Utf8)) {
        if ($line -match '^\s*(#|$)') { continue }
        $f = $line -split "`t"
        if ($f.Count -ne 5) { throw "vivac: help-registry.tsv: expected 5 fields: $line" }
        $rows += [pscustomobject]@{ Bind = $f[0]; Pane = $f[1]; Type = $f[2]; Action = $f[3]; Label = $f[4] }
    }
    $rows
}

# A binding as it is printed on the keys: MOD+shift+oem_period -> Alt+Shift+.
function Format-VivacBind([string]$Bind, [string]$Mod) {
    $names = @{ mod = 'Alt'; shift = 'Shift'; control = 'Ctrl'; enter = 'Enter'; space = 'Space'; left = 'Left'
        right = 'Right'; up = 'Up'; down = 'Down'; oem_period = '.'; oem_comma = ','; escape = 'Esc' }
    if ($Mod -eq 'lwin') { $names['mod'] = 'Win' }
    $parts = foreach ($part in ($Bind -split '\+')) {
        $key = $part.ToLowerInvariant()
        if ($names.ContainsKey($key)) { $names[$key] }
        elseif ($key -match '^(f\d+|[a-z0-9])$') { $key.ToUpperInvariant() }
        else { $part }
    }
    $parts -join '+'
}

# docs/keys.md: the registry again, for readers without a session. Rendered
# by scripts/render.ps1 and checked for drift like every other render.
function Get-VivacKeysMarkdown {
    [void](Import-VivacStrings 'en')
    $rows = Read-VivacHelpRegistry
    $titles = [ordered]@{ wm = 'Window manager'; browser = 'Browser'; shell = 'Shell'; editor = 'Editor'; system = 'System' }
    $anchors = @{ wm = 'window-manager'; browser = 'browser'; shell = 'shell'; editor = 'editor'; system = 'system' }
    $out = @('# Keys', '',
        '<!-- Rendered by scripts/render.ps1 from data/help-registry.tsv and i18n/en.conf. Do not edit. -->', '',
        'The same registry the help pane (`MOD+F1`) reads. `MOD` is the modifier chosen in the settings',
        'file: `Alt` by default, or the Windows key (`mod=lwin`).', '')
    foreach ($pane in $titles.Keys) {
        $out += "## $($titles[$pane])"
        $out += "<a id=`"$($anchors[$pane])`"></a>"
        $out += ''
        $out += '| Keys | Action |'
        $out += '|---|---|'
        foreach ($r in $rows | Where-Object { $_.Pane -eq $pane }) {
            $out += "| ``$((Format-VivacBind $r.Bind 'alt') -replace '^Alt', 'MOD')`` | $(Get-VivacString $r.Label) |"
        }
        $out += ''
    }
    ($out -join "`n")
}

Export-ModuleMember -Function * -Alias T
