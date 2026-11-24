# The sessions panel (lib/SessionsPanel.psm1): what the owner's sesiones.ps1
# prints, read as a photo, and the panel built from it. The script is a fake
# (VIVAC_SESIONES) that prints what the real `ver` prints and records the
# verbs it is run with; nothing here restores or saves anything real.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$utf8 = New-Object Text.UTF8Encoding $false
$dir = New-TempProfile
try {
    Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
    Set-VivacSetting language en
    [void](Import-VivacStrings 'en')
    Import-Module (Join-Path $root 'lib\SessionsPanel.psm1') -Force

    $fake = Join-Path $dir 'sesiones.ps1'
    $calls = Join-Path $dir 'calls.txt'
    $env:FAKE_SES_CALLS = $calls
    $env:FAKE_SES_FAIL = ''
    [IO.File]::WriteAllText($fake, @'
param([Parameter(Position = 0)][string]$Accion = 'ver')
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Content -LiteralPath $env:FAKE_SES_CALLS -Value $Accion -Encoding UTF8
if ($env:FAKE_SES_FAIL -and $Accion -eq 'guardar') { exit 1 }
if ($Accion -eq 'ver') {
    'Foto del 2026-11-13T10:20:30'
    '  [1] Terminal: Claude «trabajo» + Hermes abc'
    '  [2] chrome: Correo'
    '  [1] code: proyecto'
}
'@, (New-Object Text.UTF8Encoding $true))
    $env:VIVAC_SESIONES = $fake
    function Read-Calls { if (Test-Path -LiteralPath $calls) { @([IO.File]::ReadAllLines($calls)) } else { @() } }

    Case 'the photo is read from what ver prints: when it was taken, and the windows with their workspace' {
        $photo = ConvertFrom-VivacSessionsView "Foto del 2026-11-13T10:20:30`n  [1] Terminal: Claude «a» + Hermes x`n  [12] chrome: Correo`n"
        Assert-Equal '2026-11-13 10:20' $photo.Taken
        Assert-Equal 2 @($photo.Windows).Count
        Assert-Equal '1' @($photo.Windows)[0].Workspace
        Assert-Equal 'Terminal: Claude «a» + Hermes x' @($photo.Windows)[0].Title
        $none = ConvertFrom-VivacSessionsView ''
        Assert-Equal '' $none.Taken
        Assert-Equal 0 @($none.Windows).Count
    }
    Case 'windows are grouped by workspace, in numeric order' {
        $g = @(Group-VivacSessionsWindows @(
                [pscustomobject]@{ Workspace = '10'; Title = 'c' }, [pscustomobject]@{ Workspace = '2'; Title = 'b' },
                [pscustomobject]@{ Workspace = '10'; Title = 'd' }, [pscustomobject]@{ Workspace = '1'; Title = 'a' }))
        Assert-Equal '1,2,10' (($g | ForEach-Object { $_.Workspace }) -join ',')
        Assert-Equal 'c,d' (@($g[2].Titles) -join ',')
    }
    Case 'a restore needs a second press; anything else in between disarms it' {
        $gate = New-VivacRestoreGate
        Assert-True (-not $gate.Press()) 'the first press restored'
        Assert-True $gate.Armed 'not armed after the first press'
        Assert-True $gate.Press() 'the second press did not restore'
        Assert-True (-not $gate.Armed) 'still armed after restoring'
        [void]$gate.Press(); $gate.Cancel()
        Assert-True (-not $gate.Press()) 'a cancelled gate restored on one press'
    }
    Case 'the script is found where the owner keeps it, or where the gates point' {
        Assert-Equal $fake (Get-VivacSessionsScript)
        Assert-True (Test-VivacSessionsAvailable) 'the fake is not found'
        $env:VIVAC_SESIONES = Join-Path $dir 'gone.ps1'
        Assert-True (-not (Test-VivacSessionsAvailable)) 'a missing script is available'
        Remove-Item Env:VIVAC_SESIONES
        Assert-Equal (Join-Path $env:USERPROFILE 'bin\sesiones.ps1') (Get-VivacSessionsScript)
        $env:VIVAC_SESIONES = $fake
    }
    Case 'ver, save and restore run the owner''s verbs and no other' {
        $photo = Get-VivacSessionsPhoto
        Assert-Equal 3 @($photo.Windows).Count
        Assert-True (Invoke-VivacSessionsSave) 'save failed'
        Assert-True (Start-VivacSessionsRestore) 'restore did not start'
        $deadline = (Get-Date).AddSeconds(20)
        while ((Read-Calls) -notcontains 'restaurar' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Assert-Equal 'ver,guardar,restaurar' ((Read-Calls) -join ',')
        $env:FAKE_SES_FAIL = '1'
        try { Assert-True (-not (Invoke-VivacSessionsSave)) 'a failed save said ok' } finally { $env:FAKE_SES_FAIL = '' }
    }
    Case 'the panel shows when the photo was taken, what a restore brings back and the windows by workspace' {
        $w = Show-Sessions -NoShow
        Assert-Equal (T 'sessions.taken' @('2026-11-13 10:20')) $w.FindName('Subtitle').Text
        Assert-Equal (T 'sessions.brings_back') $w.FindName('Facts').Text
        $list = $w.FindName('WindowsList')
        $texts = @($list.Children | ForEach-Object { if ($_ -is [Windows.Controls.TextBlock]) { $_.Text } })
        Assert-True ($texts -contains (T 'sessions.workspace' @('1'))) 'workspace 1 not named'
        Assert-True ($texts -contains 'chrome: Correo') 'a window of the photo is missing'
        Assert-Equal 'Collapsed' $w.FindName('Confirm').Visibility.ToString()
        Assert-True $w.FindName('RestoreButton').IsEnabled 'restore is off with a photo'
        Assert-True $w.FindName('SaveButton').IsEnabled 'save is off'
        $w.Close()
    }
    Case 'without the owner''s script the panel says so and offers nothing' {
        $env:VIVAC_SESIONES = Join-Path $dir 'gone.ps1'
        $w = Show-Sessions -NoShow
        Assert-Equal (T 'sessions.missing') $w.FindName('Subtitle').Text
        Assert-True (-not $w.FindName('RestoreButton').IsEnabled) 'restore is on without the script'
        Assert-True (-not $w.FindName('SaveButton').IsEnabled) 'save is on without the script'
        $w.Close()
        $env:VIVAC_SESIONES = $fake
    }
}
finally {
    Remove-Item Env:VIVAC_SESIONES, Env:FAKE_SES_CALLS, Env:FAKE_SES_FAIL -ErrorAction SilentlyContinue
    Remove-TempProfile $dir
}
Complete-Cases
