# The surfaces Windows draws itself: the wallpaper, the accent colour and the
# light/dark switch. None of them is a file vivac can own, so instead of a
# manifest they get a snapshot: the values found before vivac first changed
# them are saved once, and scripts/uninstall.ps1 puts exactly those back.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')

$script:Root = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------- wallpaper

function Read-AestheticRows {
    $rows = @{}
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $script:Root 'data\aesthetics.tsv'))) {
        if ($line -match '^\s*(#|$)') { continue }
        $f = $line -split "`t"
        $rows[$f[0]] = [pscustomobject]@{ Name = $f[0]; Axis = $f[1]; Hexes = @($f[2] -split ','); Ornament = ($f[3] -eq 'yes') }
    }
    $rows
}

function Get-RootDistance([string]$A, [string]$B) {
    if ($A -eq $B) { return 0 }
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $script:Root 'data\root-distance.tsv'))) {
        if ($line -match '^\s*(#|$)') { continue }
        $f = $line -split "`t"
        if (($f[0] -eq $A -and $f[1] -eq $B) -or ($f[0] -eq $B -and $f[1] -eq $A)) { return [int]$f[2] }
    }
    throw "vivac: no distance between roots '$A' and '$B'"
}

# A theme may claim an ornament only when it has earned one: its two roots are
# an affinity (distance <= 2), or it names an aesthetic that tolerates
# ornament and actually carries that aesthetic's canonical colours. A claim
# that fails is an error, never a quiet downgrade -- the claim is what is
# wrong. Returns the ornament name, or '' for a theme that claims none.
function Get-VivacOrnament($Theme) {
    if (-not $Theme.Meta.Contains('ornament')) { return '' }
    $ornament = $Theme.Meta['ornament']
    $template = Join-Path $script:Root "templates\wallpaper\ornament-$ornament.svg.in"
    if (-not (Test-Path -LiteralPath $template)) { throw "vivac: $($Theme.Name) claims ornament '$ornament', which does not exist" }
    if ($Theme.Meta.Contains('dominant') -and $Theme.Meta.Contains('accent')) {
        if ((Get-RootDistance $Theme.Meta['dominant'] $Theme.Meta['accent']) -le 2) { return $ornament }
    }
    if ($Theme.Meta.Contains('aesthetic')) {
        $rows = Read-AestheticRows
        $a = $rows[$Theme.Meta['aesthetic']]
        if (-not $a) { throw "vivac: $($Theme.Name) names unknown aesthetic '$($Theme.Meta['aesthetic'])'" }
        $carried = @($Theme.Tokens.Values)
        $missing = @($a.Hexes | Where-Object { $carried -notcontains $_ })
        if ($a.Ornament -and -not $missing.Count) { return $ornament }
    }
    throw "vivac: $($Theme.Name) claims ornament '$ornament' without an affinity or an aesthetic that grants it"
}

# The SVG source: the shared composition, the ornament if earned, and the
# closing tag base.svg.in deliberately leaves off.
function Get-VivacWallpaperSvg($Theme) {
    $tokens = Get-VivacTokens -Theme $Theme
    $svg = Expand-VivacTemplate -Text (Read-VivacText (Join-Path $script:Root 'templates\wallpaper\base.svg.in')) -Tokens $tokens -Facts $null
    $ornament = Get-VivacOrnament $Theme
    if ($ornament) {
        $svg += Expand-VivacTemplate -Text (Read-VivacText (Join-Path $script:Root "templates\wallpaper\ornament-$ornament.svg.in")) -Tokens $tokens -Facts $null
    }
    $svg.TrimEnd() + "`n</svg>`n"
}

# Rasterize with the Edge that ships with Windows 11, headless: it renders SVG
# faithfully, gradients and opacity included, and needs nothing installed.
function ConvertTo-VivacPng([string]$SvgPath, [string]$PngPath, [int]$Width = 3840, [int]$Height = 2160) {
    $edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (-not (Test-Path -LiteralPath $edge)) { $edge = Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }
    if (-not (Test-Path -LiteralPath $edge)) { throw 'vivac: Microsoft Edge not found; it is needed to rasterize the wallpaper' }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('vivac-wall-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        Copy-Item -LiteralPath $SvgPath -Destination (Join-Path $work 'w.svg')
        $html = "<!doctype html><html><body style='margin:0;overflow:hidden'><img src='w.svg' width='$Width' height='$Height' style='display:block'></body></html>"
        [IO.File]::WriteAllText((Join-Path $work 'w.html'), $html)
        $shot = Join-Path $work 'w.png'
        $url = 'file:///' + (($work -replace '\\', '/') + '/w.html')
        # Start-Process in 5.1 joins arguments with spaces and quotes nothing,
        # so a path argument is quoted here.
        $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
            "--user-data-dir=`"$work\profile`"", "--screenshot=`"$shot`"", "--window-size=$Width,$Height", "`"$url`"")
        $p = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -Wait -WindowStyle Hidden
        if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $shot)) { throw "vivac: Edge did not render the wallpaper (exit $($p.ExitCode))" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PngPath) | Out-Null
        Move-Item -LiteralPath $shot -Destination $PngPath -Force
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The wallpaper for a theme, rendered once and kept: the file name carries a
# hash of the SVG, so a changed palette or template renders anew and an
# unchanged one is reused.
function Get-VivacWallpaper($Theme, [switch]$DryRun) {
    # A palette made from a picture wears that picture. It is copied here
    # first, under a name that carries its hash: the original may sit on a
    # shared disk the desktop cannot read at sign-in.
    if ($Theme.PSObject.Properties['Picture'] -and $Theme.Picture) {
        $hash = (Get-VivacHash $Theme.Picture).Substring(0, 12)
        $copy = Join-Path (Get-VivacPaths).Wallpapers ("$($Theme.Name)-$hash" + [IO.Path]::GetExtension($Theme.Picture))
        if (-not $DryRun -and -not (Test-Path -LiteralPath $copy)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $copy) | Out-Null
            Copy-Item -LiteralPath $Theme.Picture -Destination $copy -Force
        }
        return $copy
    }
    $svg = Get-VivacWallpaperSvg $Theme
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($svg))) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    $sha.Dispose()
    $dir = (Get-VivacPaths).Wallpapers
    $png = Join-Path $dir "$($Theme.Name)-$hash.png"
    if (-not $DryRun -and -not (Test-Path -LiteralPath $png)) {
        $svgPath = Join-Path $dir "$($Theme.Name)-$hash.svg"
        Write-VivacFile -Path $svgPath -Text $svg
        ConvertTo-VivacPng -SvgPath $svgPath -PngPath $png
    }
    $png
}

# -------------------------------------------------------- registry & native

$script:Native = $null
function Get-Native {
    if ($script:Native) { return $script:Native }
    if (-not ('Vivac.Native' -as [type])) {
        Add-Type -Namespace Vivac -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(uint action, uint param, string vparam, uint winIni);
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
'@
    }
    $script:Native = [Vivac.Native]
    $script:Native
}

$script:RegistryValues = @(
    @{ Key = 'HKCU:\Control Panel\Desktop'; Name = 'WallPaper' },
    @{ Key = 'HKCU:\Control Panel\Desktop'; Name = 'WallpaperStyle' },
    @{ Key = 'HKCU:\Control Panel\Desktop'; Name = 'TileWallpaper' },
    @{ Key = 'HKCU:\Control Panel\Desktop'; Name = 'AutoColorization' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'AccentColorMenu' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'StartColorMenu' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'AccentPalette' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'AccentColor' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'ColorizationColor' },
    @{ Key = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'ColorizationAfterglow' }
)

function Get-OriginalSnapshotPath { Join-Path (Get-VivacPaths).State 'windows-original.json' }

# Saved once, before the first change, and never overwritten: the second
# deploy must not record the first deploy's values as "original".
function Save-VivacWindowsOriginal {
    $path = Get-OriginalSnapshotPath
    if (Test-Path -LiteralPath $path) { return }
    $entries = @()
    foreach ($v in $script:RegistryValues) {
        $item = Get-ItemProperty -LiteralPath $v.Key -Name $v.Name -ErrorAction SilentlyContinue
        $present = $null -ne $item
        $value = $null; $kind = ''
        if ($present) {
            $raw = $item.($v.Name)
            if ($raw -is [byte[]]) { $kind = 'Binary'; $value = [Convert]::ToBase64String($raw) }
            elseif ($raw -is [int] -or $raw -is [long]) { $kind = 'DWord'; $value = [int64]$raw }
            else { $kind = 'String'; $value = [string]$raw }
        }
        $entries += [pscustomobject]@{ Key = $v.Key; Name = $v.Name; Present = $present; Kind = $kind; Value = $value }
    }
    Write-VivacFile -Path $path -Text (($entries | ConvertTo-Json -Depth 4) + "`n")
}

function Restore-VivacWindowsOriginal {
    $path = Get-OriginalSnapshotPath
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    foreach ($e in (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)) {
        if (-not $e.Present) {
            Remove-ItemProperty -LiteralPath $e.Key -Name $e.Name -ErrorAction SilentlyContinue
            continue
        }
        if (-not (Test-Path -LiteralPath $e.Key)) { New-Item -Path $e.Key -Force | Out-Null }
        switch ($e.Kind) {
            'Binary' { Set-ItemProperty -LiteralPath $e.Key -Name $e.Name -Value ([Convert]::FromBase64String($e.Value)) -Type Binary }
            'DWord'  { Set-ItemProperty -LiteralPath $e.Key -Name $e.Name -Value ([int]$e.Value) -Type DWord }
            default  { Set-ItemProperty -LiteralPath $e.Key -Name $e.Name -Value ([string]$e.Value) -Type String }
        }
    }
    $wall = (Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction SilentlyContinue).WallPaper
    $native = Get-Native
    [void]$native::SystemParametersInfo(20, 0, [string]$wall, 3)
    Send-VivacSettingChange
    Remove-Item -LiteralPath $path -Force
    $true
}

function Send-VivacSettingChange {
    $native = Get-Native
    $out = [UIntPtr]::Zero
    foreach ($area in 'ImmersiveColorSet', 'WindowsThemeElement') {
        [void]$native::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, $area, 2, 2000, [ref]$out)
    }
}

# Registry DWORDs for colours are ABGR; a palette entry is R,G,B,A bytes.
function ConvertTo-Abgr([string]$Hex, [int]$Alpha = 0xFF) {
    $r = [Convert]::ToInt32($Hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($Hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($Hex.Substring(4, 2), 16)
    [BitConverter]::ToInt32([byte[]]@($r, $g, $b, $Alpha), 0)
}

function ConvertTo-Argb([string]$Hex, [int]$Alpha = 0xC4) {
    $r = [Convert]::ToInt32($Hex.Substring(0, 2), 16)
    $g = [Convert]::ToInt32($Hex.Substring(2, 2), 16)
    $b = [Convert]::ToInt32($Hex.Substring(4, 2), 16)
    [BitConverter]::ToInt32([byte[]]@($b, $g, $r, $Alpha), 0)
}

# Windows wants eight shades of the accent for Start, Settings and the
# taskbar. They are derived, like the wallpaper's gradients: three toward the
# foreground, the accent itself, three toward black, and the surface.
function Get-AccentPalette($Theme) {
    $accent = $Theme.Tokens['COLOR_ACCENT']
    $fg = $Theme.Tokens['COLOR_FG']
    $mix = {
        param($a, $b, [double]$t)
        $o = ''
        foreach ($i in 0, 2, 4) {
            $x = [Convert]::ToInt32($a.Substring($i, 2), 16); $y = [Convert]::ToInt32($b.Substring($i, 2), 16)
            $o += '{0:X2}' -f [int][Math]::Round($x + ($y - $x) * $t)
        }
        $o
    }
    $shades = @(
        (& $mix $accent $fg 0.6), (& $mix $accent $fg 0.4), (& $mix $accent $fg 0.2), $accent,
        (ConvertTo-VivacScaled $accent 78), (ConvertTo-VivacScaled $accent 60), (ConvertTo-VivacScaled $accent 45),
        $Theme.Tokens['COLOR_SURFACE'])
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($s in $shades) {
        foreach ($i in 0, 2, 4) { $bytes.Add([Convert]::ToByte($s.Substring($i, 2), 16)) }
        $bytes.Add(0xFF)
    }
    [pscustomobject]@{ Shades = $shades; Bytes = $bytes.ToArray() }
}

# ------------------------------------------------------------- lock screen

# The lock screen is Windows' own, which is the point: it is the one that
# actually guards the session (a full-screen window drawn by vivac would not).
# What vivac owns is how it looks: the theme's wallpaper, there and on the
# sign-in screen, and nothing of Windows' rotating tips and adverts.
#
# The picture lives outside the user profile, where the lock screen (running
# before anyone signs in) can read it, and the setting is machine-wide. Both
# need an administrator once: apply-system.ps1 -LockScreen creates them and
# hands this user the right to change them, after which every theme switch
# updates the lock screen without elevation. Each switch writes a new file
# name, because Windows keeps showing a cached picture for a path it knows.
$script:LockDir = Join-Path $env:ProgramData 'vivac'
$script:LockCsp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'

function Test-VivacLockScreenManaged {
    Test-Path -LiteralPath (Join-Path (Get-VivacPaths).State 'lockscreen-managed')
}

function Update-VivacLockScreen([string]$Png) {
    $name = 'lockscreen-' + [IO.Path]::GetFileNameWithoutExtension($Png) + '.png'
    $dest = Join-Path $script:LockDir $name
    if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $Png -Destination $dest -Force }
    if (-not (Test-Path -LiteralPath $script:LockCsp)) { New-Item -Path $script:LockCsp -Force | Out-Null }
    # Opened for SetValue only, the right Grant-VivacLockScreenToUser hands out:
    # Set-ItemProperty asks for KEY_WRITE, which includes CreateSubKey, and is
    # turned away without elevation.
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP',
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [Security.AccessControl.RegistryRights]'SetValue, QueryValues')
    try {
        $key.SetValue('LockScreenImagePath', $dest, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('LockScreenImageUrl', $dest, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('LockScreenImageStatus', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally { $key.Close() }
    foreach ($old in @(Get-ChildItem -LiteralPath $script:LockDir -Filter 'lockscreen-*.png' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $name })) {
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
    $dest
}

# Elevated, once: the folder and the setting, writable by this user from then on.
function Grant-VivacLockScreenToUser {
    New-Item -ItemType Directory -Force -Path $script:LockDir | Out-Null
    if (-not (Test-Path -LiteralPath $script:LockCsp)) { New-Item -Path $script:LockCsp -Force | Out-Null }
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $script:LockDir
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($who, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $script:LockDir -AclObject $acl
    # -Path, not -LiteralPath: in Windows PowerShell 5.1 Get-Acl and Set-Acl do not
    # resolve a registry drive path given literally.
    $racl = Get-Acl -Path $script:LockCsp
    $racl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($who, 'SetValue,QueryValues,ReadKey', 'None', 'None', 'Allow')))
    Set-Acl -Path $script:LockCsp -AclObject $racl
    Write-VivacFile -Path (Join-Path (Get-VivacPaths).State 'lockscreen-managed') -Text "1`n"
}

# Apply the theme to what Windows draws. Returns a list of what changed (or
# would change, under -DryRun).
function Set-VivacDesktop($Theme, [switch]$DryRun) {
    $report = @()
    $png = Get-VivacWallpaper -Theme $Theme -DryRun:$DryRun
    $report += "wallpaper: $png"
    $report += "accent: #$($Theme.Tokens['COLOR_ACCENT']) (dark mode on)"
    $managed = Test-VivacLockScreenManaged
    if ($managed) { $report += "lock screen: the same wallpaper" }
    if ($DryRun) { return $report }
    if ($managed) { try { [void](Update-VivacLockScreen $png) } catch { $report += "lock screen: not updated ($($_.Exception.Message))" } }
    # GRUB's menu and the boot logo (apply-system.ps1 -Boot): two more
    # renders and a SYSTEM task, seconds the theme switch does not wait for.
    if (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'vivac\boot-sync.ps1')) {
        $boot = Join-Path $script:Root 'lib\Boot.psm1'
        $cmd = "Import-Module '$boot'; Update-VivacBoot '$($Theme.Name)'"
        Start-Process powershell.exe -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-Command', "`"$cmd`"" -WindowStyle Hidden | Out-Null
        $report += "boot menu and logo: the same theme"
    }

    Save-VivacWindowsOriginal
    $desktop = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty -LiteralPath $desktop -Name WallpaperStyle -Value '10' -Type String
    Set-ItemProperty -LiteralPath $desktop -Name TileWallpaper -Value '0' -Type String
    Set-ItemProperty -LiteralPath $desktop -Name AutoColorization -Value 0 -Type DWord
    $native = Get-Native
    if (-not $native::SystemParametersInfo(20, 0, $png, 3)) { throw "vivac: Windows refused the wallpaper $png" }

    $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $personalize)) { New-Item -Path $personalize -Force | Out-Null }
    Set-ItemProperty -LiteralPath $personalize -Name AppsUseLightTheme -Value 0 -Type DWord
    Set-ItemProperty -LiteralPath $personalize -Name SystemUsesLightTheme -Value 0 -Type DWord

    $palette = Get-AccentPalette $Theme
    $accentKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent'
    if (-not (Test-Path $accentKey)) { New-Item -Path $accentKey -Force | Out-Null }
    Set-ItemProperty -LiteralPath $accentKey -Name AccentPalette -Value $palette.Bytes -Type Binary
    Set-ItemProperty -LiteralPath $accentKey -Name AccentColorMenu -Value (ConvertTo-Abgr $palette.Shades[3]) -Type DWord
    Set-ItemProperty -LiteralPath $accentKey -Name StartColorMenu -Value (ConvertTo-Abgr $palette.Shades[5]) -Type DWord
    $dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
    Set-ItemProperty -LiteralPath $dwm -Name AccentColor -Value (ConvertTo-Abgr $palette.Shades[3]) -Type DWord
    Set-ItemProperty -LiteralPath $dwm -Name ColorizationColor -Value (ConvertTo-Argb $palette.Shades[3]) -Type DWord
    Set-ItemProperty -LiteralPath $dwm -Name ColorizationAfterglow -Value (ConvertTo-Argb $palette.Shades[3]) -Type DWord
    Send-VivacSettingChange
    $report
}

Export-ModuleMember -Function *
