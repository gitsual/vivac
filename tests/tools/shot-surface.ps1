<#
.SYNOPSIS
  Renders one of vivac's surfaces to a PNG, off screen and without taking
  the focus: for looking at a surface while someone works at the machine.

.EXAMPLE
  powershell -STA -File tests\tools\shot-surface.ps1 -Command 'Show-Menu' -Name menu -Out C:\tmp\menu.png
  -Setup runs inside the surface once it is open, with $w the window.
  -Prepare runs inside the last of -Modules before the surface opens: for
  feeding a surface sample data the machine does not have.
  -Scrub is a list of 'real=>sample' pairs (regular expressions on the left)
  applied to every text on the surface right before the capture, so a picture
  meant for publishing carries no name, address or network of this machine.
#>
param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Out,
    [string]$Setup = '',
    [string]$Prepare = '',
    [string[]]$Modules = @(),
    [string[]]$Scrub = @(),
    [int]$WaitMs = 3500
)
$ErrorActionPreference = 'Stop'
# The same three through the environment, for a caller whose arguments would
# not survive a command line (regular expressions, quotes):
# VIVAC_SHOT_SETUP, VIVAC_SHOT_PREPARE, VIVAC_SHOT_SCRUB (one pair a line).
if (-not $Setup -and $env:VIVAC_SHOT_SETUP) { $Setup = $env:VIVAC_SHOT_SETUP }
if (-not $Prepare -and $env:VIVAC_SHOT_PREPARE) { $Prepare = $env:VIVAC_SHOT_PREPARE }
if (-not $Scrub.Count -and $env:VIVAC_SHOT_SCRUB) { $Scrub = @($env:VIVAC_SHOT_SCRUB -split "`n" | Where-Object { $_ }) }
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $repo 'lib\Vivac.psm1') -Force
$mods = @('Surfaces') + $Modules
foreach ($m in $mods) {
    $mod = Import-Module (Join-Path $repo "lib\$m.psm1") -Force -PassThru -Global
    & $mod {
        function script:Set-VivacForeground($Window) { }
        $script:shotOrigNew = ${function:New-VivacWindow}
        if ($script:shotOrigNew) {
            function script:New-VivacWindow([string]$Xaml) {
                $w = & $script:shotOrigNew $Xaml
                $w.ShowActivated = $false
                $w.Add_Loaded({ param($s) $s.Left = -6000; $s.Top = 0 })
                $w
            }
        }
    }
}
$global:shotState = @{ Step = 0; Setup = $Setup; Out = $Out; Name = $Name; Ticks = [int]($WaitMs / 250); Scrub = $Scrub }

# Every text on the surface, with the pairs applied: TextBlocks (their runs
# too), text boxes and content strings, found through the visual tree.
function global:Invoke-ShotScrub($Root, [string[]]$Pairs) {
    if (-not $Pairs.Count) { return }
    $rules = foreach ($pair in $Pairs) { $k, $v = $pair -split '=>', 2; , @($k, $v) }
    $fix = { param([string]$t) foreach ($r in $rules) { $t = $t -replace $r[0], $r[1] }; $t }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count) {
        $o = $stack.Pop()
        if ($o -is [Windows.Controls.TextBlock]) {
            if ($o.Inlines.Count) { foreach ($run in @($o.Inlines | Where-Object { $_ -is [Windows.Documents.Run] })) { $run.Text = & $fix $run.Text } }
            else { $o.Text = & $fix $o.Text }
        } elseif ($o -is [Windows.Controls.TextBox]) { $o.Text = & $fix $o.Text }
        elseif ($o -is [Windows.Controls.ContentControl] -and $o.Content -is [string]) { $o.Content = & $fix $o.Content }
        if ($o -is [Windows.Media.Visual] -or $o -is [Windows.Media.Media3D.Visual3D]) {
            $n = [Windows.Media.VisualTreeHelper]::GetChildrenCount($o)
            for ($i = 0; $i -lt $n; $i++) { $stack.Push([Windows.Media.VisualTreeHelper]::GetChild($o, $i)) }
        }
    }
}
$reg = @{}
$global:shotReg = $reg
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
        $w = $global:shotReg[$global:shotState.Name]; if (-not $w -or -not $w.IsLoaded) { return }
        $global:shotState.Step++
        if ($global:shotState.Step -eq 1 -and $global:shotState.Setup) { & ([scriptblock]::Create($global:shotState.Setup)) }
        if ($global:shotState.Step -ge $global:shotState.Ticks) {
            $w.UpdateLayout()
            # Pairs only known at capture time (the networks in range now),
            # from a script the caller passes in VIVAC_SHOT_SCRUBSCRIPT.
            $late = @()
            if ($env:VIVAC_SHOT_SCRUBSCRIPT) { try { $late = @(& ([scriptblock]::Create($env:VIVAC_SHOT_SCRUBSCRIPT))) } catch { Write-Host "scrub script: $($_.Exception.Message)" } }
            Invoke-ShotScrub $w (@($late) + @($global:shotState.Scrub))
            $w.UpdateLayout()
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$w.ActualWidth), ([int]$w.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($w.Content)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create($global:shotState.Out); $enc.Save($fs); $fs.Close()
            Write-Host "saved $($global:shotState.Out) ($([int]$w.ActualWidth)x$([int]$w.ActualHeight))"
            $this.Stop(); $w.Close()
        }
    })
if ($Prepare) { & $mod ([scriptblock]::Create($Prepare)) }
$timer.Start()
& $Command -Registry $reg
