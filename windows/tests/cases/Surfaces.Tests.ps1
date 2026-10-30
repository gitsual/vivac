# vivac's own windows: each one builds in every theme, and the help pane
# offers exactly the registry's rows plus any live binding it does not know.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$dir = New-TempProfile
try {
    Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
    foreach ($name in Get-VivacCatalogue) {
        Case "the surfaces build in $name" {
            Set-VivacSetting theme $name
            Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
            foreach ($w in (Show-Sound -NoShow), (Show-Menu -NoShow), (Show-Help -NoShow), (Show-Power -NoShow), (Show-ThemePicker -NoShow)) {
                Assert-True ($w -is [Windows.Window]) 'a window'
                Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
            }
        }
    }
    Case 'the menu carries everything the Start menu reaches' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $entries = @(Get-VivacMenuEntries)
        foreach ($g in 'apps', 'folders', 'settings', 'tools', 'session') {
            Assert-True (@($entries | Where-Object { $_.Group -eq $g }).Count -gt 0) "no $g in the menu"
        }
        Assert-Equal @(Get-StartApps | Where-Object { $_.AppID -ne 'Microsoft.Windows.Shell.RunDialog' }).Count @($entries | Where-Object { $_.Group -eq 'apps' }).Count 'every app the Start menu lists but its Run dialog'
        $confirm = @($entries | Where-Object { $_.Confirm } | ForEach-Object { $_.Target }) -join ','
        Assert-Equal 'logout,restart,shutdown' $confirm 'what ends the session asks first'
    }
    Case 'the switch key opens the power menu with Restart in Linux armed, one press from the restart' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $surfaces = Get-Module Surfaces | Select-Object -First 1
        & $surfaces { $script:RebootOther = $true }
        $confirm = & $surfaces { T 'power.confirm' }
        $other = & $surfaces { T 'power.other' }
        $plain = Show-Power -NoShow
        $armed = Show-Power -NoShow -Arm other
        $last = 5
        Assert-Equal $other $plain.FindName("L$last").Text 'the plain power menu arms nothing'
        Assert-Equal $confirm $armed.FindName("L$last").Text 'Restart in Linux is armed'
        Assert-Equal (& $surfaces { T 'power.restart' }) $armed.FindName('L3').Text 'nothing else is armed'
        $unknown = Show-Power -NoShow -Arm nothing
        Assert-Equal $other $unknown.FindName("L$last").Text 'an entry that is not there arms nothing'
        & $surfaces { $script:RebootOther = $null }
    }
    Case 'menu matching ignores case and accents' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        Assert-Equal 'configuracion de red' (ConvertTo-MenuKey ("Configuraci" + [char]0x00F3 + "n de RED"))
    }    Case 'the notification and the volume indicator are vivac windows that never take the focus' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $n = New-VivacNotification 'vivac' 'test'
        $osd = New-VivacVolumeOsd
        foreach ($w in $n, $osd.Window) {
            Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
            Assert-Equal $false $w.ShowActivated 'does not steal the focus'
            Assert-True $w.Topmost
        }
    }
    Case 'the menu runs what is typed; Windows Run dialog is not offered' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $entries = @(Get-VivacMenuEntries)
        Assert-True (-not @($entries | Where-Object { $_.Target -match 'RunDialog|2559a1f3' }).Count) 'the Windows Run dialog is gone'
    }    Case 'the help pane lists every wm row of the registry' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $w = Show-Help -NoShow
        $rows = $w.FindName('Rows')
        $expected = @(Read-VivacHelpRegistry | Where-Object { $_.Pane -eq 'wm' }).Count
        Assert-Equal $expected $rows.Items.Count
    }
    Case 'a live binding the registry does not know shows up as UNREGISTERED' {
        $cfg = Join-Path $env:VIVAC_PROFILE '.glzr\glazewm\config.yaml'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cfg) | Out-Null
        [IO.File]::WriteAllText($cfg, "keybindings:`n  - commands: ['close']`n    bindings: ['lwin+q']`n  - commands: ['wm-redraw']`n    bindings: ['lwin+shift+y']`n")
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        $rows = (Show-Help -NoShow).FindName('Rows')
        $texts = @($rows.Items | ForEach-Object { ($_.Inlines | ForEach-Object { $_.Text }) -join '' })
        Assert-Equal 1 @($texts | Where-Object { $_ -match 'UNREGISTERED' }).Count
        Assert-True (@($texts | Where-Object { $_ -match 'lwin\+shift\+y\s+UNREGISTERED' }).Count -eq 1)
    }
    Case 'the security surface builds in every theme and the bar gets a state it knows' {
        foreach ($name in Get-VivacCatalogue) {
            Set-VivacSetting theme $name
            Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
            Import-Module (Join-Path $root 'lib\Security.psm1') -Force
            $w = Show-Security -NoShow
            Assert-True ($w -is [Windows.Window]) 'a window'
            Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
            $w.Close()
        }
        $sum = Get-VivacSecuritySummary
        Assert-True (@('ok', 'warn', 'alert') -contains $sum.state) "state $($sum.state)"
        Assert-True ($sum.tip) 'a tooltip'
    }
    Case 'the lock asks for the PIN until the password is the way in, and back' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        Assert-Equal 'pin' (Get-VivacLockMode) 'the PIN first'
        Set-VivacLockMode password
        Assert-Equal 'password' (Get-VivacLockMode)
        $w = Show-VivacLock -NoShow -Greeter
        Assert-Equal 'Visible' ([string]$w.FindName('Secret').Visibility) 'the field takes the password'
        $w.Close()
        Set-VivacLockMode pin
        $w = Show-VivacLock -NoShow -Greeter
        Assert-Equal 'Collapsed' ([string]$w.FindName('Secret').Visibility) 'nothing typed in the field: the PIN goes to Windows Hello'
        Assert-True ([string]$w.FindName('ModeSwitch').Content) 'a way to the password'
        $w.Close()
        Set-Content -LiteralPath (Join-Path (Get-VivacPaths).State 'lock-mode') -Value 'nonsense'
        Assert-Equal 'pin' (Get-VivacLockMode) 'anything else is the PIN'
    }
    Case 'a PIN typed as the password is told apart' {
        Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
        Assert-True (Test-VivacLooksLikePin '1234')
        Assert-True (-not (Test-VivacLooksLikePin '12a4')) 'letters: a password'
        Assert-True (-not (Test-VivacLooksLikePin '123')) 'too short for a PIN'
    }
} finally { Remove-TempProfile $dir }
Complete-Cases
