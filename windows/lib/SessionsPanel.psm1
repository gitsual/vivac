# The owner's session photos (bin\sesiones.ps1, not part of vivac) as a panel
# of the common design, where the bar's sessions button used to ask nothing
# and restore at once. What it shows is what the script prints itself:
# `ver` gives the date of the last photo and its windows, one line each as
# "  [workspace] ...". Restoring reopens every window in the photo, open or
# not, so it takes a second press, as power's restart does; saving is one.
# Linux keeps the same panel in linux/lib/vivacpanel/sessions.py.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Phone.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')
Import-Module (Join-Path $PSScriptRoot 'KitDraw.psm1')
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')

# Where the owner keeps the script; VIVAC_SESIONES points the gates at a fake.
function Get-VivacSessionsScript {
    if ($env:VIVAC_SESIONES) { return $env:VIVAC_SESIONES }
    Join-Path $env:USERPROFILE 'bin\sesiones.ps1'
}
function Test-VivacSessionsAvailable { Test-Path -LiteralPath (Get-VivacSessionsScript) -PathType Leaf }

# `ver`: "Foto del 2026-11-13T10:20:30" and then "  [1] Terminal: ..." lines.
function ConvertFrom-VivacSessionsView([string]$Text) {
    $taken = ''; $windows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $taken -and $line -match '^Foto del (\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})') { $taken = "$($Matches[1]) $($Matches[2])"; continue }
        if ($line -match '^\s*\[(\d+)\]\s+(.+?)\s*$') { $windows += [pscustomobject]@{ Workspace = $Matches[1]; Title = $Matches[2] } }
    }
    [pscustomobject]@{ Taken = $taken; Windows = $windows }
}

function Group-VivacSessionsWindows([object[]]$Windows) {
    @($Windows | Group-Object Workspace | Sort-Object { [int]$_.Name } | ForEach-Object {
        [pscustomobject]@{ Workspace = $_.Name; Titles = @($_.Group | ForEach-Object { $_.Title }) }
    })
}

# Two presses: the first arms (the panel says what comes back), the second
# restores. Esc, or another button, disarms.
class VivacRestoreGate {
    [bool]$Armed = $false
    [bool] Press() {
        if ($this.Armed) { $this.Armed = $false; return $true }
        $this.Armed = $true
        return $false
    }
    [void] Cancel() { $this.Armed = $false }
}
function New-VivacRestoreGate { New-Object VivacRestoreGate }

# The script, run with one of its own verbs and no other, in a hidden window.
function Start-VivacSessionsVerb([ValidateSet('ver', 'guardar', 'restaurar')][string]$Verb, [switch]$Capture) {
    $script = ConvertTo-VivacArgument (Get-VivacSessionsScript)
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe', "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script $Verb"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    if ($Capture) { $psi.RedirectStandardOutput = $true; $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding $false }
    [Diagnostics.Process]::Start($psi)
}

# The last photo, as `ver` describes it; empty when the script says nothing.
function Get-VivacSessionsPhoto {
    if (-not (Test-VivacSessionsAvailable)) { return (ConvertFrom-VivacSessionsView '') }
    try {
        $proc = Start-VivacSessionsVerb ver -Capture
        $out = $proc.StandardOutput.ReadToEndAsync()
        if (-not $proc.WaitForExit(20000)) { try { $proc.Kill() } catch { }; return (ConvertFrom-VivacSessionsView '') }
        ConvertFrom-VivacSessionsView ([string]$out.Result)
    } catch { ConvertFrom-VivacSessionsView '' }
}

function Invoke-VivacSessionsSave {
    try {
        $proc = Start-VivacSessionsVerb guardar
        if (-not $proc.WaitForExit(60000)) { try { $proc.Kill() } catch { }; return $false }
        $proc.ExitCode -eq 0
    } catch { $false }
}

# Restoring takes a while and the script logs it itself: started, not waited on.
function Start-VivacSessionsRestore {
    try { [void](Start-VivacSessionsVerb restaurar); $true } catch { $false }
}

function Show-Sessions([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'sessions' }
    $p = Get-Palette
    $t = Get-PanelTokens $p
    $available = Test-VivacSessionsAvailable
    $photo = Get-VivacSessionsPhoto
    $count = @($photo.Windows).Count
    $subtitle = $(if (-not $available) { T 'sessions.missing' } elseif ($photo.Taken) { T 'sessions.taken' @($photo.Taken) } else { T 'sessions.none' })
    $ret = [string][char]0x23CE
    $hints = @(@('R', (T 'sessions.restore')), @('G', (T 'sessions.save')), @('Esc', (T 'power.key.close')))
    $facts = ''
    if ($available -and $count) { $facts = T 'sessions.brings_back' }
    $section = ''
    if ($count) { $section = Get-PanelSectionXaml $t (T 'sessions.windows') '' $count }
    $body = @"
<StackPanel>
  <TextBlock x:Name="Facts" TextWrapping="Wrap" FontSize="13" Margin="2,0,2,8" Foreground="#$($t.textSecondary)"/>
  $section
  <ScrollViewer MaxHeight="300" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="WindowsList" Margin="2,4,2,0"/></ScrollViewer>
  <UniformGrid Columns="2" Margin="0,12,0,0">
    <StackPanel Margin="0,0,4,0">$(Get-PanelButtonXaml $t 'RestoreButton' (T 'sessions.restore') 'restart' 'primary' 38)</StackPanel>
    <StackPanel Margin="4,0,0,0">$(Get-PanelButtonXaml $t 'SaveButton' (T 'sessions.save') 'download' 'neutral' 38)</StackPanel>
  </UniformGrid>
  <Border x:Name="Confirm" Visibility="Collapsed" Margin="0,12,0,0" CornerRadius="10" Padding="12,8" Background="#$($t.alertSoft)" BorderThickness="1" BorderBrush="#$($t.alert)">
    <TextBlock x:Name="ConfirmText" FontSize="13" FontWeight="Bold" TextWrapping="Wrap" Foreground="#$($t.alertText)"/>
  </Border>
  <TextBlock x:Name="Outcome" Visibility="Collapsed" Margin="2,10,2,0" FontSize="13" TextWrapping="Wrap"/>
</StackPanel>
"@
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - sessions' 560 (Get-KitPanelXamlV2 $t ([string][char]0xE81C) (T 'sessions.title') $body $hints))
    $window.FindName('Subtitle').Text = $subtitle
    $window.FindName('Facts').Text = $facts
    $window.FindName('Facts').Visibility = $(if ($facts) { 'Visible' } else { 'Collapsed' })
    $window.FindName('ConfirmText').Text = T 'sessions.confirm' @($count)
    $list = $window.FindName('WindowsList')
    foreach ($g in (Group-VivacSessionsWindows $photo.Windows)) {
        $head = New-Object Windows.Controls.TextBlock
        $head.Text = T 'sessions.workspace' @($g.Workspace)
        $head.FontSize = 12; $head.FontWeight = 'Bold'; $head.Margin = '0,6,0,2'
        $head.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFromString("#$($t.accent)")
        [void]$list.Children.Add($head)
        foreach ($title in $g.Titles) {
            $row = New-Object Windows.Controls.TextBlock
            $row.Text = $title; $row.FontSize = 13; $row.Margin = '12,1,0,1'; $row.TextTrimming = 'CharacterEllipsis'
            [void]$list.Children.Add($row)
        }
    }
    $restoreButton = $window.FindName('RestoreButton'); $saveButton = $window.FindName('SaveButton')
    $restoreButton.IsEnabled = $available -and $count -gt 0
    $saveButton.IsEnabled = $available
    $confirm = $window.FindName('Confirm'); $outcome = $window.FindName('Outcome')
    $gate = New-VivacRestoreGate
    $brush = New-Object Windows.Media.BrushConverter

    $paint = { $confirm.Visibility = $(if ($gate.Armed) { 'Visible' } else { 'Collapsed' }) }
    $say = {
        param([bool]$ok, [string]$text)
        $outcome.Text = $text
        $outcome.Foreground = $brush.ConvertFromString("#$(if ($ok) { $t.successText } else { $t.alertText })")
        $outcome.Visibility = 'Visible'
    }
    $doRestore = {
        if (-not $restoreButton.IsEnabled) { return }
        if (-not $gate.Press()) { & $paint; return }
        & $paint
        if (Start-VivacSessionsRestore) { $window.Close() } else { & $say $false (T 'sessions.save_failed') }
    }
    $doSave = {
        if (-not $saveButton.IsEnabled) { return }
        $gate.Cancel(); & $paint
        $saveButton.IsEnabled = $false
        # Saving walks every window and process: the panel keeps answering meanwhile.
        $proc = Start-VivacSessionsVerb guardar
        $timer = New-Object Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(200)
        $timer.Add_Tick({
            if (-not $proc.HasExited) { return }
            $timer.Stop()
            $saveButton.IsEnabled = $true
            if ($proc.ExitCode -eq 0) { & $say $true (T 'sessions.saved') } else { & $say $false (T 'sessions.save_failed') }
        }.GetNewClosure())
        $timer.Start()
    }
    $restoreButton.Add_Click({ & $doRestore }.GetNewClosure())
    $saveButton.Add_Click({ & $doSave }.GetNewClosure())
    $window.Add_PreviewKeyDown({
        param($s, $e)
        $k = [string]$e.Key
        if ($k -eq 'Escape') { if ($gate.Armed) { $gate.Cancel(); & $paint } else { $window.Close() }; $e.Handled = $true; return }
        if ($k -eq 'R' -or $k -eq 'Return') { & $doRestore; $e.Handled = $true; return }
        if ($k -eq 'G') { & $doSave; $e.Handled = $true; return }
    }.GetNewClosure())
    if ($NoShow) { return $window }
    if ($Registry) { $Registry['sessions'] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Get-VivacSessionsScript, Test-VivacSessionsAvailable, ConvertFrom-VivacSessionsView, Group-VivacSessionsWindows, New-VivacRestoreGate, Get-VivacSessionsPhoto, Invoke-VivacSessionsSave, Start-VivacSessionsRestore, Show-Sessions
