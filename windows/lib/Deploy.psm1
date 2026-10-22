# Deployment: what goes where, and how it lands without losing anything.
#
# Windows has no GNU Stow and symlinks need Developer Mode or elevation, so a
# deploy here is a copy, made safe by bookkeeping instead of by links:
#
#   - every file vivac writes is recorded with its hash in the manifest
#   - a target that already exists and is not byte-for-byte what vivac wrote
#     last time is the user's, and it is copied to a timestamped backup first
#   - a file vivac wrote earlier that no package claims any more is removed
#     only if it is still unchanged; an edited one is left and reported
#
# The plan is computed first and applied second, so a dry run is the same
# code path minus the writes.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')

$script:Root = Split-Path -Parent $PSScriptRoot
$script:Packages = @('glazewm', 'zebar', 'flow', 'terminal', 'nvim')

function Get-VivacPackages { $script:Packages }

function Get-RelativePath([string]$Base, [string]$Path) {
    $Path.Substring($Base.TrimEnd('\').Length + 1)
}

# --------------------------------------------------------------------- plan

# A plan item: Package, Target (absolute path), Text (UTF-8 content) and Kind
# (themed | render | static | merge). Binary files are not part of any
# package, so every item is text and every comparison is exact.
function New-PlanItem($Package, $Target, $Text, $Kind, $Source) {
    [pscustomobject]@{ Package = $Package; Target = $Target; Text = $Text; Kind = $Kind; Source = $Source }
}

# Themed templates see the palette and nothing else, which is what lets their
# default render be committed under dotfiles/ and checked for drift.
function Get-ThemedRender($Theme, [string]$Package) {
    $dir = Join-Path $script:Root "templates\$Package"
    $out = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    $tokens = Get-VivacTokens -Theme $Theme
    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.in' | Sort-Object FullName) {
        $rel = (Get-RelativePath $dir $f.FullName) -replace '\.in$', ''
        $text = Expand-VivacTemplate -Text (Read-VivacText $f.FullName) -Tokens $tokens -Facts $null
        $out += [pscustomobject]@{ Relative = $rel; Text = $text; Source = $f.FullName }
    }
    $out
}

# Machine renders see the palette, the settings, the facts and the repository
# path; their guards can test facts and settings (as set_<key>).
function Get-MachineContext($Theme, $Settings, $Facts) {
    $tokens = Get-VivacTokens -Theme $Theme -Settings $Settings -Facts $Facts
    $weather = 'null'
    $w = $Settings['weather_location']
    if ($w -eq 'auto') { $weather = '{}' }
    elseif ($w -match '^(-?[\d.]+),(-?[\d.]+)$') { $weather = "{ latitude: $($Matches[1]), longitude: $($Matches[2]) }" }
    $tokens['WEATHER_JSON'] = $weather
    $tokens['PIPE_NAME'] = Get-VivacPipeName
    $labels = [ordered]@{}
    foreach ($k in 'desktop', 'wired', 'no_link', 'not_connected', 'no_address', 'theme', 'power', 'bt_on', 'bt_off', 'eject', 'updates', 'updates_none', 'updates_apps', 'updates_security', 'reboot', 'av_on', 'av_off', 'phone_reachable',
        'feels', 'humidity', 'wind', 'rain', 'next_hours', 'week', 'today', 'loading', 'forecast_unavailable',
        'wx_clear', 'wx_partly', 'wx_cloudy', 'wx_fog', 'wx_drizzle', 'wx_rain', 'wx_snow', 'wx_showers', 'wx_thunder',
        'cpu', 'memory', 'disks', 'cores', 'frequency', 'vendor', 'free', 'swap', 'free_of', 'top', 'loading_top', 'vram', 'gpu_power', 'fan') {
        $labels[$k] = Get-VivacString "bar.$k"
    }
    $tokens['BAR_LABELS_JSON'] = ($labels | ConvertTo-Json -Compress)
    $predicates = [ordered]@{}
    foreach ($k in $Facts.Keys) { $predicates[$k] = $Facts[$k] }
    foreach ($k in $Settings.Keys) { $predicates["set_$k"] = $Settings[$k] }
    [pscustomobject]@{ Tokens = $tokens; Predicates = $predicates }
}

function Get-MachineRender($Context, [string]$Package) {
    $dir = Join-Path $script:Root "render\$Package"
    $out = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.in' | Sort-Object FullName) {
        $rel = (Get-RelativePath $dir $f.FullName) -replace '\.in$', ''
        $text = Expand-VivacTemplate -Text (Read-VivacText $f.FullName) -Tokens $Context.Tokens -Facts $Context.Predicates
        $out += [pscustomobject]@{ Relative = $rel; Text = $text; Source = $f.FullName }
    }
    $out
}

function Get-StaticFiles([string]$Package) {
    $dir = Join-Path $script:Root "static\$Package"
    $out = @()
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File | Sort-Object FullName) {
        $out += [pscustomobject]@{ Relative = (Get-RelativePath $dir $f.FullName); Text = (Read-VivacText $f.FullName); Source = $f.FullName }
    }
    $out
}

# ------------------------------------------------------------ JSON merging

# Windows Terminal accepts JSON with comments. Windows PowerShell's parser
# does not, so comments outside strings are dropped before parsing; the file
# is then written back as plain JSON, and the original was backed up first.
function Remove-JsonComments([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0; $n = $Text.Length; $inString = $false
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
            if ($c -eq '"') { $inString = $false }
            $i++; continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2)
            if ($end -lt 0) { throw 'vivac: unterminated comment in JSON' }
            $i = $end + 2; continue
        }
        [void]$sb.Append($c); $i++
    }
    # Trailing commas are legal for Windows Terminal and fatal for 5.1.
    [regex]::Replace($sb.ToString(), ',(\s*[\]}])', '$1')
}

function ConvertTo-PrettyJson($Object) {
    # 5.1 escapes <, >, & and ' as < and so on; that is valid JSON and
    # Windows Terminal reads it, but it is put back for whoever reads the file.
    $json = $Object | ConvertTo-Json -Depth 32
    $json = $json -replace '\\u0026', '&' -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0027', "'"
    ($json -replace "`r`n", "`n") + "`n"
}

function Set-JsonProperty($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# The terminal: one scheme named vivac, made the default for every profile,
# plus the bar's font. Nothing else in the user's settings is touched.
function Get-TerminalMerge([string]$CurrentText, [string]$SchemeText) {
    $settings = Remove-JsonComments $CurrentText | ConvertFrom-Json
    $scheme = $SchemeText | ConvertFrom-Json
    $schemes = @()
    if ($settings.PSObject.Properties['schemes']) { $schemes = @($settings.schemes | Where-Object { $_.name -ne 'vivac' }) }
    $schemes += $scheme
    Set-JsonProperty $settings 'schemes' $schemes
    if (-not $settings.PSObject.Properties['profiles']) { Set-JsonProperty $settings 'profiles' ([pscustomobject]@{ defaults = [pscustomobject]@{}; list = @() }) }
    if ($settings.profiles -is [array]) { throw 'vivac: this Windows Terminal settings file uses the old profiles array; open and save it once in Windows Terminal first' }
    if (-not $settings.profiles.PSObject.Properties['defaults']) { Set-JsonProperty $settings.profiles 'defaults' ([pscustomobject]@{}) }
    $defaults = $settings.profiles.defaults
    Set-JsonProperty $defaults 'colorScheme' 'vivac'
    Set-JsonProperty $defaults 'opacity' 95
    Set-JsonProperty $defaults 'cursorShape' 'bar'
    Set-JsonProperty $defaults 'padding' '4'
    Set-JsonProperty $defaults 'font' ([pscustomobject]@{ face = 'JetBrainsMono Nerd Font'; size = 11 })
    ConvertTo-PrettyJson $settings
}

# The launcher: the vivac theme. MOD+R is vivac's menu (render/glazewm), so
# Flow Launcher's own hotkey is left to its owner -- except the MOD+R an
# earlier vivac set there, which would now fight the window manager for the
# same keys and is put back to Flow Launcher's default.
#
# Flow Launcher saves this file itself whenever it exits, so, as with the
# bar's start-up list, a file that already says the right thing is returned
# exactly as found.
function Get-FlowMerge([string]$CurrentText) {
    $settings = $CurrentText | ConvertFrom-Json
    $hotkey = ''
    if ($settings.PSObject.Properties['Hotkey']) { $hotkey = [string]$settings.Hotkey }
    $stale = @('Alt + R', 'Win + R') -contains $hotkey
    if ($settings.PSObject.Properties['Theme'] -and $settings.Theme -eq 'vivac' -and -not $stale) {
        return $CurrentText
    }
    Set-JsonProperty $settings 'Theme' 'vivac'
    if ($stale) { Set-JsonProperty $settings 'Hotkey' 'Alt + Space' }
    ConvertTo-PrettyJson $settings
}

# The bar's start-up list. Zebar rewrites this file on every start, stamping
# its own version into $schema and re-indenting it, so the file is merged
# rather than owned: when the vivac bar is already the one widget started,
# the text is returned exactly as found and the deploy sees no change.
function Get-ZebarSettingsMerge([string]$CurrentText) {
    $want = [pscustomobject]@{ pack = 'vivac'; widget = 'bar'; preset = 'default' }
    $settings = $null
    if ($CurrentText) { try { $settings = $CurrentText | ConvertFrom-Json } catch { $settings = $null } }
    if ($settings -and $settings.PSObject.Properties['startupConfigs']) {
        $configs = @($settings.startupConfigs)
        if ($configs.Count -eq 1 -and $configs[0].pack -eq 'vivac' -and $configs[0].widget -eq 'bar' -and $configs[0].preset -eq 'default') {
            return $CurrentText
        }
    }
    if (-not $settings) { $settings = [pscustomobject]@{} }
    Set-JsonProperty $settings 'startupConfigs' @($want)
    ConvertTo-PrettyJson $settings
}

function Get-FlowSettingsPath {
    Join-Path (Get-VivacPaths).AppData 'FlowLauncher\Settings\Settings.json'
}

# The whole plan for the chosen packages.
function Get-VivacPlan($Theme, $Settings, $Facts, [string[]]$Packages) {
    $context = Get-MachineContext $Theme $Settings $Facts
    $plan = @()
    foreach ($pkg in $Packages) {
        if ($script:Packages -notcontains $pkg) { throw "vivac: unknown package '$pkg' (known: $($script:Packages -join ', '))" }
        if ($pkg -eq 'terminal') {
            $target = Get-VivacTerminalSettingsPath
            if (Test-Path -LiteralPath $target) {
                $scheme = (Get-ThemedRender $Theme 'terminal' | Where-Object { $_.Relative -eq 'vivac-scheme.json' }).Text
                $plan += New-PlanItem $pkg $target (Get-TerminalMerge (Read-VivacText $target) $scheme) 'merge' 'templates\terminal\vivac-scheme.json.in'
            }
            continue
        }
        $root = Get-VivacTargetRoot $pkg
        foreach ($f in Get-ThemedRender $Theme $pkg) { $plan += New-PlanItem $pkg (Join-Path $root $f.Relative) $f.Text 'themed' $f.Source }
        foreach ($f in Get-MachineRender $context $pkg) { $plan += New-PlanItem $pkg (Join-Path $root $f.Relative) $f.Text 'render' $f.Source }
        foreach ($f in Get-StaticFiles $pkg) { $plan += New-PlanItem $pkg (Join-Path $root $f.Relative) $f.Text 'static' $f.Source }
        if ($pkg -eq 'zebar') {
            $target = Join-Path $root 'settings.json'
            $current = ''
            if (Test-Path -LiteralPath $target) { $current = Read-VivacText $target }
            $plan += New-PlanItem $pkg $target (Get-ZebarSettingsMerge $current) 'merge' 'lib\Deploy.psm1'
        }
        if ($pkg -eq 'flow') {
            $target = Get-FlowSettingsPath
            if (Test-Path -LiteralPath $target) {
                $plan += New-PlanItem $pkg $target (Get-FlowMerge (Read-VivacText $target)) 'merge' 'lib\Deploy.psm1'
            }
        }
    }
    $plan
}

# ----------------------------------------------------------------- manifest

function Read-VivacManifest {
    $path = (Get-VivacPaths).Manifest
    $m = @{}
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if (-not $line) { continue }
            $f = $line -split "`t"
            $m[$f[0]] = [pscustomobject]@{ Target = $f[0]; Hash = $f[1]; Package = $f[2] }
        }
    }
    $m
}

function Write-VivacManifest($Entries) {
    $lines = @($Entries.Values | Sort-Object Target | ForEach-Object { "$($_.Target)`t$($_.Hash)`t$($_.Package)" })
    Write-VivacFile -Path (Get-VivacPaths).Manifest -Text (($lines -join "`n") + "`n")
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Text)
        ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# Apply a plan. Returns one result per touched path:
#   Action = new | update | unchanged | backup+update | removed | kept-edited
# Restricting -Packages means only those packages' manifest entries are
# considered for removal; the rest of the manifest is carried over as is.
function Invoke-VivacPlan($Plan, [string[]]$Packages, [switch]$DryRun) {
    $paths = Get-VivacPaths
    $manifest = Read-VivacManifest
    $next = @{}
    foreach ($k in $manifest.Keys) {
        if ($Packages -notcontains $manifest[$k].Package) { $next[$k] = $manifest[$k] }
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path $paths.Backups $stamp
    $results = @()
    foreach ($item in $Plan) {
        $hash = Get-TextHash $item.Text
        $action = 'new'
        if (Test-Path -LiteralPath $item.Target) {
            $current = Get-VivacHash $item.Target
            if ($current -eq $hash) {
                $action = 'unchanged'
            } elseif ($manifest.ContainsKey($item.Target) -and $manifest[$item.Target].Hash -eq $current) {
                $action = 'update'
            } else {
                $action = 'backup+update'
            }
        }
        if (-not $DryRun) {
            if ($action -eq 'backup+update') {
                $safe = ($item.Target -replace '^[A-Za-z]:\\', '')
                $dest = Join-Path $backupRoot $safe
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
                Copy-Item -LiteralPath $item.Target -Destination $dest -Force
            }
            if ($action -ne 'unchanged') { Write-VivacFile -Path $item.Target -Text $item.Text }
        }
        $next[$item.Target] = [pscustomobject]@{ Target = $item.Target; Hash = $hash; Package = $item.Package }
        $results += [pscustomobject]@{ Package = $item.Package; Target = $item.Target; Action = $action; Kind = $item.Kind }
    }
    # Files vivac wrote before that the plan no longer claims.
    $planned = @{}
    foreach ($item in $Plan) { $planned[$item.Target] = $true }
    foreach ($k in $manifest.Keys) {
        $entry = $manifest[$k]
        if ($Packages -notcontains $entry.Package -or $planned.ContainsKey($k)) { continue }
        if (-not (Test-Path -LiteralPath $k)) { continue }
        if ((Get-VivacHash $k) -eq $entry.Hash) {
            if (-not $DryRun) { Remove-Item -LiteralPath $k -Force }
            $results += [pscustomobject]@{ Package = $entry.Package; Target = $k; Action = 'removed'; Kind = '' }
        } else {
            $next[$k] = $entry
            $results += [pscustomobject]@{ Package = $entry.Package; Target = $k; Action = 'kept-edited'; Kind = '' }
        }
    }
    if (-not $DryRun) { Write-VivacManifest $next }
    $results
}

# Deploy integrity: every manifest entry still exists with the hash vivac
# wrote. A mismatch is a file someone edited after the deploy.
function Test-VivacDeployIntegrity {
    $problems = @()
    $m = Read-VivacManifest
    foreach ($k in $m.Keys) {
        if (-not (Test-Path -LiteralPath $k)) { $problems += "missing: $k"; continue }
        if ((Get-VivacHash $k) -ne $m[$k].Hash) { $problems += "edited since deploy: $k" }
    }
    $problems
}

Export-ModuleMember -Function *
