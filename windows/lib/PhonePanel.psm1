# The phone as a panel of the common design, where the bar's phone button
# used to open the menu on its Phone category. Same kit as the power panel:
# tiles with a number key, an outcome line under them, and the panel stays
# open. What it does is Phone.psm1's (kdeconnect-cli), so the menu, the
# bin/vivac-phone.ps1 verbs and this panel act the same.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Phone.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')
Import-Module (Join-Path $PSScriptRoot 'KitDraw.psm1')
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')

# The text on the clipboard, or '' (it needs the UI thread's apartment, and
# something else may be holding the clipboard at that moment).
function Get-VivacClipboardText {
    try { if ([Windows.Clipboard]::ContainsText()) { return [string][Windows.Clipboard]::GetText() } } catch { }
    ''
}

function Show-Phone([switch]$NoShow, [hashtable]$Registry) {
    Update-SurfaceContext
    if (-not $NoShow -and -not $Registry) { Enter-SingleInstance 'phone' }
    $p = Get-Palette
    $t = Get-PanelTokens $p
    $installed = [bool](Get-VivacPhoneCli)
    $phones = @()
    if ($installed) { $phones = @(Get-VivacPhoneDevices) }
    $phone = $null
    if ($phones.Count) { $phone = $phones[0] }
    $tiles = @(Get-VivacPhoneTiles $installed $phones (Test-VivacPhoneLink (Get-VivacClipboardText)))

    $cells = ''
    for ($i = 0; $i -lt $tiles.Count; $i++) {
        $cells += @"
<Border x:Name="B$i" Height="124" Margin="5" CornerRadius="12" Background="#$($t.surface)" BorderThickness="2" BorderBrush="Transparent" Cursor="Hand">
  <StackPanel VerticalAlignment="Center">
    <TextBlock HorizontalAlignment="Center" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="28" Foreground="#$($t.accent)" Text="$($tiles[$i].Glyph)"/>
    <TextBlock HorizontalAlignment="Center" Margin="8,10,8,0" FontSize="13" FontWeight="Bold" TextAlignment="Center" TextWrapping="Wrap" Foreground="#$($t.text)" Text="$(ConvertTo-XmlText $tiles[$i].Label)"/>
    <Border HorizontalAlignment="Center" Margin="0,10,0,0" CornerRadius="6" Padding="7,1" BorderThickness="1" BorderBrush="#$($t.line)"><TextBlock FontSize="12" Foreground="#$($t.textSecondary)" Text="$($i + 1)"/></Border>
  </StackPanel>
</Border>
"@
    }
    $ret = [string][char]0x23CE
    $arrows = [string][char]0x2190 + [string][char]0x2192
    $hints = @(@("1-$($tiles.Count)", (T 'power.key.choose')), @($arrows, (T 'power.key.move')), @($ret, (T 'power.key.activate')), @('Esc', (T 'power.key.close')))
    $body = "<StackPanel><UniformGrid Columns=`"3`">$cells</UniformGrid><TextBlock x:Name=`"Outcome`" Visibility=`"Collapsed`" Margin=`"6,10,6,0`" FontSize=`"13`" TextWrapping=`"Wrap`" Foreground=`"#$($t.textSecondary)`"/></StackPanel>"
    $window = New-VivacWindow (Get-KitWindowXamlV2 $t 'vivac - phone' 560 (Get-KitPanelXamlV2 $t ([string][char]0xE8EA) (T 'phone.title') $body $hints))
    $window.FindName('Subtitle').Text = Get-VivacPhoneSubtitle $installed $phones
    $outcome = $window.FindName('Outcome')
    $state = @{ Index = 0 }

    $paint = {
        for ($i = 0; $i -lt $tiles.Count; $i++) {
            $b = $window.FindName("B$i")
            if ($i -eq $state.Index) { $b.BorderBrush = "#$($t.focusRing)"; $b.Background = "#$($t.surfaceAlt)" }
            else { $b.BorderBrush = 'Transparent'; $b.Background = "#$($t.surface)" }
            $b.Opacity = $(if ($tiles[$i].Enabled) { 1.0 } else { 0.38 })
        }
    }
    $say = {
        param($r)
        $outcome.Text = [string]$r.Message
        $outcome.Foreground = "#$(if ($r.Ok) { $t.successText } else { $t.alertText })"
        $outcome.Visibility = $(if ($r.Message) { 'Visible' } else { 'Collapsed' })
    }
    $run = {
        param($i)
        $tile = $tiles[$i]
        if (-not $tile.Enabled) {
            if ($tile.Key -eq 'send-url') { & $say ([pscustomobject]@{ Ok = $false; Message = (T 'phone.no_link') }) }
            return
        }
        $state.Index = $i; & $paint
        $id = ''; $name = ''
        if ($phone) { $id = [string]$phone.id; $name = [string]$phone.name }
        switch ($tile.Key) {
            'manage' { $r = Invoke-VivacPhoneAction manage $id $name; if ($r.Ok) { $window.Close() } else { & $say $r } }
            'send-file' {
                # The dialog takes the focus; the panel must stay under it.
                $window.Resources['vivac.keep'] = $true
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    $dialog = New-Object Windows.Forms.OpenFileDialog
                    $dialog.Title = T 'phone.pick_file'
                    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { & $say (Invoke-VivacPhoneAction send-file $id $name -File $dialog.FileName) }
                } finally { $window.Resources.Remove('vivac.keep'); [void]$window.Activate() }
            }
            'send-url' { & $say (Invoke-VivacPhoneAction send-url $id $name -Url (Get-VivacClipboardText).Trim()) }
            default { & $say (Invoke-VivacPhoneAction $tile.Key $id $name) }
        }
    }

    for ($i = 0; $i -lt $tiles.Count; $i++) {
        $idx = $i
        $window.FindName("B$i").Add_MouseLeftButtonUp({ & $run $idx }.GetNewClosure())
    }
    $window.Add_PreviewKeyDown({
        param($s, $e)
        $k = [string]$e.Key
        if ($k -eq 'Escape') { $window.Close(); return }
        $to = $state.Index
        if ($k -eq 'Left') { $to-- } elseif ($k -eq 'Right') { $to++ } elseif ($k -eq 'Up') { $to -= 3 } elseif ($k -eq 'Down') { $to += 3 }
        if ($to -ne $state.Index) {
            if ($to -ge 0 -and $to -lt $tiles.Count) { $state.Index = $to; & $paint }
            return
        }
        if (($k -match '^D([1-9])$' -or $k -match '^NumPad([1-9])$') -and [int]$Matches[1] -le $tiles.Count) { & $run ([int]$Matches[1] - 1); return }
        if ($k -eq 'Return' -or $k -eq 'Space') { & $run $state.Index; return }
    })
    & $paint
    if ($NoShow) { return $window }
    if ($Registry) { $Registry['phone'] = $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Show-Phone, Get-VivacClipboardText
