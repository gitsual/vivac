# What the sound panel decides before it draws anything: a device's short
# name, the applications out of the mixer's sessions, and the signature that
# says whether what is on screen is stale. Pure functions, no window, no COM:
# tests/cases/SoundPanel.Tests.ps1 runs them anywhere.

Set-StrictMode -Version 2.0

# Windows names a device "Speakers (Realtek(R) Audio)": the kind, then what
# carries it. The panel reads "Speakers - Realtek(R) Audio" (a middle dot between them), the way the
# Linux side shortens "Starship/Matisse HD Audio Controller Stereo". The
# full name stays in the tooltip.
function Get-SoundShortName([string]$Name) {
    if (-not $Name) { return '' }
    if ($Name -match '^(?<kind>.*?)\s*\((?<what>.+)\)\s*$' -and $Matches['kind']) {
        return "$($Matches['kind']) $([char]0x00B7) $($Matches['what'])"
    }
    $Name
}

# One entry per program: a program with several sessions (a browser has one
# per tab that plays) is one row, its level the loudest session's, muted only
# when every session is, playing when any session is. Sorted by name.
function Group-SoundSessions([object[]]$Sessions) {
    $apps = foreach ($g in @($Sessions) | Group-Object Name) {
        $all = @($g.Group)
        [pscustomobject]@{
            Name      = [string]$g.Name
            ProcessId = [uint32]$all[0].ProcessId
            Volume    = [int](($all | Measure-Object Volume -Maximum).Maximum)
            Muted     = -not @($all | Where-Object { -not $_.Muted }).Count
            Playing   = [bool]@($all | Where-Object { $_.Active }).Count
            Indexes   = @($all | ForEach-Object { [int]$_.Index })
        }
    }
    @($apps | Sort-Object { $_.Name.ToLowerInvariant() })
}

# Which of the three lines under an application's name it gets.
function Get-SoundAppState($App) {
    if ($App.Muted) { 'silenced' } elseif ($App.Playing) { 'playing' } else { 'paused' }
}

# What a redraw would show, as one string: the panel compares it to the last
# one and only repaints when it differs, so a level moved elsewhere or an
# application starting is followed without the panel flickering at a poll.
function Get-SoundSignature([object[]]$Outputs, [object[]]$Inputs, [object[]]$Apps) {
    $part = {
        param($devices)
        (@($devices) | ForEach-Object { "$($_.Id)/$($_.IsDefault)/$($_.Volume)/$($_.Muted)" }) -join ','
    }
    $appPart = (@($Apps) | ForEach-Object { "$($_.Name)/$($_.Volume)/$($_.Muted)/$($_.Playing)/$($_.Indexes.Count)" }) -join ','
    "O:$(& $part $Outputs)|I:$(& $part $Inputs)|A:$appPart"
}

# The numbers under a fader: quarters of 0 .. 100 (0/25/50/75/100, where
# Windows' scalar tops out at 100), and for a taller one the Linux panel's
# 0/50/100/Max with the unity mark at 100.
function Get-SoundRulerValues([int]$Max = 100) {
    if ($Max -gt 100) { return @(0, 50, 100, $Max) }
    $step = [int]($Max / 4)
    @(0, $step, (2 * $step), (3 * $step), $Max)
}
