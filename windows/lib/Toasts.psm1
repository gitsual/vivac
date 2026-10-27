# Other programs' notifications, drawn by vivac: top right under the bar in
# vivac's card (New-VivacNotification) instead of Windows' banners at the
# bottom right.
#
# Nothing is intercepted. Every notification still reaches Windows, which
# keeps it in its notification centre as before; vivac reads each new one
# from Windows' own record of them (lib/VivacToasts.cs, read-only) and shows
# it. What changes is only Windows' banner: with scripts/apply-system.ps1
# -Toasts, each program's "show notification banners" switch is turned off
# (ShowBanner=0 under its key in HKCU\...\Notifications\Settings, the value
# Settings > System > Notifications writes), and the resident host turns it
# off for programs that notify for the first time later. What each key held
# before is kept in toast-banners.json and put back by scripts/uninstall.ps1.
#
# Windows Security's notifications keep their own banners and are not drawn
# again here: a detection must be seen whether or not vivac is running.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')

$script:SettingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
# Windows Security and Defender: their banners stay Windows' own.
$script:Native = @('Windows.Defender.SecurityCenter', 'Microsoft.Windows.SecHealthUI_cw5n1h2txyewy!SecHealthUI', 'Windows.SystemToast.SecurityAndMaintenance')
# Keys under Notifications\Settings that are Windows' bookkeeping, not programs.
$script:NotPrograms = '^(Windows\.ActionCenter\.|Windows\.SystemToast\.(QuietHours|Suggested|HelloFace|NotificationCenter))'

function Get-ToastStatePaths {
    $state = (Get-VivacPaths).State
    @{ Marker = Join-Path $state 'toasts-managed'; Saved = Join-Path $state 'toast-banners.json' }
}

function Import-VivacToasts {
    if ('VivacToasts' -as [type]) { return }
    Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VivacToasts.cs'))) -Language CSharp
}

# --------------------------------------------------------------- the content

# A toast's XML, reduced to what the card shows: the first text is the title,
# the rest the body; the program's logo when it sent one as a local file.
function ConvertFrom-ToastPayload([string]$Payload) {
    $out = @{ Title = ''; Body = ''; Image = ''; Launch = '' }
    if (-not $Payload) { return $out }
    try { $x = [xml]$Payload } catch { return $out }
    $toast = $x.SelectSingleNode('/toast')
    if (-not $toast) { return $out }
    if ($toast.Attributes['launch']) { $out.Launch = $toast.Attributes['launch'].Value }
    $binding = $x.SelectSingleNode('/toast/visual/binding[@template="ToastGeneric"]')
    if (-not $binding) { $binding = $x.SelectSingleNode('/toast/visual/binding') }
    if (-not $binding) { return $out }
    $texts = @($binding.SelectNodes('.//text') | Where-Object { -not $_.Attributes['placement'] } | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })
    if ($texts.Count) { $out.Title = $texts[0] }
    if ($texts.Count -gt 1) { $out.Body = ($texts | Select-Object -Skip 1) -join "`n" }
    $images = @($binding.SelectNodes('.//image'))
    $logo = @($images | Where-Object { $_.Attributes['placement'] -and $_.Attributes['placement'].Value -eq 'appLogoOverride' }) + @($images | Where-Object { -not $_.Attributes['placement'] })
    foreach ($img in $logo) {
        $src = [string]$img.Attributes['src'].Value
        if ($src -match '^file:///') { $src = [Uri]::UnescapeDataString(($src -replace '^file:///', '')) -replace '/', '\' }
        if ($src -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $src)) { $out.Image = $src; break }
    }
    $out
}

# The name a person knows a program by: the Start menu's name for its app
# id, else the description of the program file, else what is left of the id.
$script:AppNames = $null
function Get-ToastAppName([string]$Aumid) {
    if ($null -eq $script:AppNames) {
        $script:AppNames = @{}
        try { foreach ($a in Get-StartApps) { $script:AppNames[[string]$a.AppID] = [string]$a.Name } } catch { }
    }
    if ($script:AppNames.ContainsKey($Aumid)) { return $script:AppNames[$Aumid] }
    $exe = Get-ToastAppPath $Aumid
    if ($exe) {
        $d = (Get-Item -LiteralPath $exe).VersionInfo.FileDescription
        if ($d) { return $d.Trim() }
        return [IO.Path]::GetFileNameWithoutExtension($exe)
    }
    if ($Aumid -match '^NotifyIconGeneratedAumid_') { return 'Windows' }
    if ($Aumid -match '^Microsoft\.SkyDrive') { return 'OneDrive' }
    ($Aumid -replace '_[a-z0-9]{13}!.*$', '' -replace '^.*\.', '')
}

# Programs without a Start menu id are known by their file path, written
# with forward slashes.
function Get-ToastAppPath([string]$Aumid) {
    if ($Aumid -match '^[A-Za-z]:[/\\].+\.exe$') {
        $p = $Aumid -replace '/', '\'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $null
}

# A click on the card brings the program up, as a click on Windows' banner
# would.
function Invoke-ToastApp([string]$Aumid) {
    $exe = Get-ToastAppPath $Aumid
    if ($exe) { Start-Process -FilePath $exe; return }
    if ($Aumid -notmatch '^(NotifyIconGeneratedAumid_|Windows\.)') { Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$Aumid" }
}

# ----------------------------------------------------------------- the stack

$script:Stack = New-Object System.Collections.Generic.List[object]
$script:MaxCards = 4
$script:Seconds = 7
$script:PauseCap = 30

function Update-ToastStack {
    $area = [Windows.SystemParameters]::WorkArea
    $top = $area.Top + 15
    foreach ($w in $script:Stack.ToArray()) {
        $w.Left = $area.Right - $w.Width - 15
        $w.Top = $top
        $top += $w.ActualHeight + 8
    }
}

# One card on the stack: newest on top, at most four, each gone after seven
# seconds unless the pointer rests on it. A card is never on screen for good:
# WPF can miss the MouseLeave (the stack reflows the card out from under a
# still pointer), so the pointer holds it at most $PauseCap seconds.
function Show-VivacToast([string]$Title, [string]$Body, [string]$App, [string]$Image = '', [string]$IconKey = '', [scriptblock]$OnClick = $null) {
    while ($script:Stack.Count -ge $script:MaxCards) { $script:Stack[$script:Stack.Count - 1].Close() }
    $w = New-VivacNotification $Title $Body $App $Image $IconKey
    $parts = $w.Tag
    $life = @{ Left = [double]$script:Seconds * 1000; Paused = $false; Held = 0.0; OnClick = $OnClick; Window = $w; Full = 380.0 }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $timer.Tag = @{ Life = $life; Parts = $parts }
    $timer.Add_Tick({
            param($s)
            $l = $s.Tag.Life
            if ($l.Paused -and $l.Held -lt $script:PauseCap * 1000) { $l.Held += 50; return }
            $l.Left -= 50
            $s.Tag.Parts.Progress.Width = [Math]::Max(0, $l.Full * $l.Left / ($script:Seconds * 1000))
            if ($l.Left -le 0) { $s.Stop(); $l.Window.Close() }
        })
    $w.Add_MouseEnter({ param($s) $s.Tag.Life.Paused = $true })
    $w.Add_MouseLeave({ param($s) $s.Tag.Life.Paused = $false })
    $parts.Life = $life
    $parts.Timer = $timer
    $parts.Close.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; [Windows.Window]::GetWindow($s).Close() })
    $w.Add_MouseLeftButtonUp({
            param($s)
            $l = $s.Tag.Life
            $s.Close()
            if ($l.OnClick) { try { & $l.OnClick } catch { } }
        })
    $w.Add_Closed({
            param($s)
            $s.Tag.Timer.Stop()
            [void]$script:Stack.Remove($s)
            Update-ToastStack
        })
    $w.Add_SizeChanged({ Update-ToastStack })
    $script:Stack.Insert(0, $w)
    $w.Show()
    Update-ToastStack
    $timer.Start()
}

# ---------------------------------------------------------------- the watch

$script:LastId = -1
$script:LastSync = [datetime]::MinValue
# When this module was loaded, as Windows stamps notifications (UTC file
# time): what arrived before is old news, what arrived while the host was
# still warming up is not.
$script:Since = [DateTime]::UtcNow.ToFileTimeUtc()

# Called by the resident host's timer: shows what arrived since the last
# call.
function Update-VivacToastWatch {
    Import-VivacToasts
    $db = [VivacToasts]::DefaultPath()
    if ($script:LastId -lt 0) {
        $script:LastId = 0
        foreach ($r in [VivacToasts]::Since($db, 0)) { if ($r.Arrival -lt $script:Since) { $script:LastId = [Math]::Max($script:LastId, $r.Id) } }
    }
    $managed = Test-Path -LiteralPath (Get-ToastStatePaths).Marker
    if ($managed -and ((Get-Date) - $script:LastSync).TotalSeconds -ge 30) { Sync-VivacToastBanners; $script:LastSync = Get-Date }
    foreach ($r in [VivacToasts]::Since($db, $script:LastId)) {
        $script:LastId = [Math]::Max($script:LastId, $r.Id)
        if (-not $managed -or $script:Native -contains $r.Aumid) { continue }
        $c = ConvertFrom-ToastPayload $r.Payload
        if (-not $c.Title -and -not $c.Body) { continue }
        $aumid = $r.Aumid
        $iconKey = ''
        $exe = Get-ToastAppPath $aumid
        if ($exe) { $iconKey = $exe } elseif ($aumid -notmatch '^(NotifyIconGeneratedAumid_|Windows\.)') { $iconKey = "shell:AppsFolder\$aumid" }
        $click = [scriptblock]::Create("Invoke-ToastApp '$($aumid -replace "'", "''")'")
        Show-VivacToast $c.Title $c.Body (Get-ToastAppName $aumid) $c.Image $iconKey $click
        # A program that notified for the first time had its banner shown by
        # Windows this once; from now on it is vivac's.
        Sync-VivacToastBanners
    }
}

# ------------------------------------------------------------- the banners

# Every program's banner off, but Windows Security's. What a key held before
# is saved the first time vivac touches it, so uninstall puts it back.
function Sync-VivacToastBanners([switch]$DryRun) {
    $paths = Get-ToastStatePaths
    $saved = @{}
    if (Test-Path -LiteralPath $paths.Saved) {
        try { (Get-Content -LiteralPath $paths.Saved -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $saved[$_.Name] = $_.Value } } catch { }
    }
    $changed = @()
    # A program id may hold backslashes (PowerShell's does), and Windows then
    # nests its key: a program's key is any key that records notifications.
    $prefix = (Get-Item -LiteralPath $script:SettingsKey).Name + '\'
    $keys = Get-ChildItem -LiteralPath $script:SettingsKey -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.GetValueNames() -contains 'LastNotificationAddedTime' -or $_.GetValueNames() -contains 'ShowBanner' }
    foreach ($k in $keys) {
        $name = $k.Name.Substring($prefix.Length)
        if ($script:Native -contains $name -or $name -match $script:NotPrograms) { continue }
        $now = (Get-ItemProperty -LiteralPath $k.PSPath -Name ShowBanner -ErrorAction SilentlyContinue)
        $value = if ($now) { [int]$now.ShowBanner } else { $null }
        if ($value -eq 0) { continue }
        if (-not $saved.ContainsKey($name)) { $saved[$name] = $value }
        $changed += $name
        if (-not $DryRun) { Set-ItemProperty -LiteralPath $k.PSPath -Name ShowBanner -Value 0 -Type DWord }
    }
    if ($changed.Count -and -not $DryRun) { Write-VivacFile -Path $paths.Saved -Text (([pscustomobject]$saved | ConvertTo-Json) + "`n") }
    $changed
}

# Hands the banners back to Windows as they were (scripts/uninstall.ps1).
function Restore-VivacToastBanners([switch]$DryRun) {
    $paths = Get-ToastStatePaths
    $restored = @()
    if (Test-Path -LiteralPath $paths.Saved) {
        $saved = Get-Content -LiteralPath $paths.Saved -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) {
            $key = "$script:SettingsKey\$($p.Name)"
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $restored += $p.Name
            if ($DryRun) { continue }
            if ($null -eq $p.Value) { Remove-ItemProperty -LiteralPath $key -Name ShowBanner -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -LiteralPath $key -Name ShowBanner -Value ([int]$p.Value) -Type DWord }
        }
        if (-not $DryRun) { Remove-Item -LiteralPath $paths.Saved -Force }
    }
    if (-not $DryRun) { Remove-Item -LiteralPath $paths.Marker -Force -ErrorAction SilentlyContinue }
    $restored
}

# Turns vivac's notifications on (scripts/apply-system.ps1 -Toasts).
function Enable-VivacToasts([switch]$DryRun) {
    $paths = Get-ToastStatePaths
    if (-not $DryRun) { Write-VivacFile -Path $paths.Marker -Text "on`n" }
    Sync-VivacToastBanners -DryRun:$DryRun
}

Export-ModuleMember -Function Import-VivacToasts, ConvertFrom-ToastPayload, Get-ToastAppName, Get-ToastAppPath, Invoke-ToastApp, Show-VivacToast, Update-VivacToastWatch, Sync-VivacToastBanners, Restore-VivacToastBanners, Enable-VivacToasts
