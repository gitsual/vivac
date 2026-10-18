# What is on screen before Windows: GRUB's menu (the first thing the firmware
# starts on this machine, shared with Arch) and the boot logo Windows draws
# over the firmware's own, replaced by HackBGRT. Both live on the EFI system
# partition, which only an administrator can mount, so this is split in two:
#
#   - this module, run as the user on every theme switch, renders the
#     pictures and writes the palette into a staging folder
#     (%ProgramData%\vivac\boot-stage), then asks for the sync task
#   - scripts\boot-sync.ps1, installed by apply-system.ps1 -Boot under
#     %ProgramFiles%\vivac where the user cannot change it, runs as SYSTEM
#     (task \vivac\boot-sync, which this user may start but not edit). It
#     takes nothing from the stage as it is: colours are checked against
#     ^[0-9A-F]{6}$, pictures are decoded and encoded anew, and the GRUB
#     theme is written by the task itself. A user-level program can choose
#     the colours of the boot menu; it cannot hand GRUB a file of its own.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Desktop.psm1')

$script:Root = Split-Path -Parent $PSScriptRoot
$script:Stage = Join-Path $env:ProgramData 'vivac\boot-stage'
$script:TaskPath = '\vivac\'
$script:TaskName = 'boot-sync'

function Get-VivacBootStage { $script:Stage }

# Mounts the EFI system partition (elevated) and returns its root, 'X:\'.
# A free-looking letter is not proof: a drive mapped in the user's session
# (WSL's, a network share) is invisible to an elevated one. So each letter is
# tried, and the mount counts only if Windows' boot loader is on it.
# scripts\boot-sync.ps1 carries the same function: it runs without the
# checkout's modules.
function Mount-VivacEsp {
    foreach ($l in [char[]](89..71)) {
        if (Test-Path "$($l):\") { continue }
        mountvol "$($l):" /s 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }
        if (Test-Path -LiteralPath "$($l):\EFI\Microsoft\Boot\bootmgfw.efi") { return "$($l):\" }
        mountvol "$($l):" /d 2>&1 | Out-Null
    }
    $null
}

function Dismount-VivacEsp([string]$Root) {
    if ($Root) { mountvol $Root.TrimEnd('\') /d 2>&1 | Out-Null }
}

function Test-VivacBootManaged {
    Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'vivac\boot-sync.ps1')
}

# The size the firmware boots at is the one the panel runs at here; both
# pictures are drawn for it so neither is scaled by GRUB or the firmware.
function Get-VivacBootResolution {
    # The video controller reports physical pixels whatever the display
    # scaling; screen bounds in a process that is not DPI aware would not.
    $v = @(Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1)
    if ($v.Count) { return @([int]$v[0].CurrentHorizontalResolution, [int]$v[0].CurrentVerticalResolution) }
    @(1920, 1080)
}

# The boot logo: the whole screen in the base colour, the coin of the brand
# mark a little above the centre (where Windows' spinner leaves room below)
# and the wordmark under it.
function Get-VivacSplashSvg($Theme, [int]$Width, [int]$Height) {
    $tokens = Get-VivacTokens -Theme $Theme
    $mark = Expand-VivacTemplate -Text (Read-VivacText (Join-Path $script:Root 'templates\brand\logo-mark.svg.in')) -Tokens $tokens -Facts $null
    $mark = ($mark -replace '(?s)<\?xml.*?\?>', '' -replace '(?s)<!--.*?-->', '').Trim()
    $size = [int][Math]::Round($Height * 0.24)
    $x = [int](($Width - $size) / 2); $y = [int]($Height * 0.382 - $size / 2)
    $mark = $mark -replace 'width="256" height="256"', "x=`"$x`" y=`"$y`" width=`"$size`" height=`"$size`""
    $font = [int][Math]::Round($Height * 0.045)
    $textY = $y + $size + [int]($font * 1.5)
    $bg = $Theme.Tokens['COLOR_BG']; $accent = $Theme.Tokens['COLOR_ACCENT']
    @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $Width $Height" width="$Width" height="$Height">
<rect width="$Width" height="$Height" fill="#$bg"/>
$mark
<text x="$([int]($Width / 2))" y="$textY" text-anchor="middle" font-family="JetBrains Mono, JetBrainsMono Nerd Font, Cascadia Mono, monospace" font-size="$font" font-weight="700" letter-spacing="-1" fill="#$accent">vivac</text>
</svg>
"@
}

# Everything the sync task needs, for the theme given: two pictures and the
# palette. Returns the staging folder.
function Write-VivacBootStage($Theme, [switch]$DryRun) {
    $res = Get-VivacBootResolution
    $w = $res[0]; $h = $res[1]
    if ($DryRun) { return $script:Stage }
    New-Item -ItemType Directory -Force -Path $script:Stage | Out-Null
    $svg = Join-Path $script:Stage 'splash.svg'
    Write-VivacFile -Path $svg -Text (Get-VivacSplashSvg $Theme $w $h)
    ConvertTo-VivacPng -SvgPath $svg -PngPath (Join-Path $script:Stage 'splash.png') -Width $w -Height $h
    $wall = Join-Path $script:Stage 'background.svg'
    Write-VivacFile -Path $wall -Text (Get-VivacWallpaperSvg $Theme)
    ConvertTo-VivacPng -SvgPath $wall -PngPath (Join-Path $script:Stage 'background.png') -Width $w -Height $h
    $lines = @("THEME=$($Theme.Name)", "WIDTH=$w", "HEIGHT=$h")
    foreach ($k in 'COLOR_BG', 'COLOR_FG', 'COLOR_FG_DIM', 'COLOR_SURFACE', 'COLOR_SURFACE_ALT', 'COLOR_ACCENT', 'COLOR_MUTED', 'COLOR_BORDER_INACTIVE') {
        $lines += "$k=$($Theme.Tokens[$k])"
    }
    Write-VivacFile -Path (Join-Path $script:Stage 'palette.conf') -Text (($lines -join "`n") + "`n")
    $script:Stage
}

# Ask SYSTEM to carry the stage onto the EFI partition. Returns at once; the
# task logs to %ProgramFiles%\vivac\boot-sync.log.
function Start-VivacBootSync {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $task = $svc.GetFolder($script:TaskPath.TrimEnd('\')).GetTask($script:TaskName)
    [void]$task.Run($null)
}

# By name, for a process of its own (lib\Desktop.psm1 starts one per switch).
function Update-VivacBoot([string]$ThemeName) {
    [void](Write-VivacBootStage (Read-VivacTheme $ThemeName))
    Start-VivacBootSync
}

Export-ModuleMember -Function Mount-VivacEsp, Dismount-VivacEsp, Get-VivacBootStage,Test-VivacBootManaged, Get-VivacBootResolution, Get-VivacSplashSvg, Write-VivacBootStage, Start-VivacBootSync, Update-VivacBoot
