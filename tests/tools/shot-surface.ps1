<#
.SYNOPSIS
  Renders one of vivac's surfaces to a PNG, off screen and without taking
  the focus: for looking at a surface while someone works at the machine.

.EXAMPLE
  powershell -STA -File tests\tools\shot-surface.ps1 -Command 'Show-Menu' -Name menu -Out C:\tmp\menu.png
  -Setup runs inside the surface once it is open, with $w the window.
  -Prepare runs inside the last of -Modules before the surface opens: for
  feeding a surface sample data the machine does not have.
#>
param(
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Out,
    [string]$Setup = '',
    [string]$Prepare = '',
    [string[]]$Modules = @(),
    [int]$WaitMs = 3500
)
$ErrorActionPreference = 'Stop'
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
$global:shotState = @{ Step = 0; Setup = $Setup; Out = $Out; Name = $Name; Ticks = [int]($WaitMs / 250) }
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
