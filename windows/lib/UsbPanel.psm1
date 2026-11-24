# The USB actions use the same WPF kit as Bluetooth and sound.
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')

function Show-UsbDriveMenu {
    param([ValidatePattern('^[A-Za-z]:$')][string]$Drive, [switch]$NoShow, [hashtable]$Registry)
    Update-SurfaceContext
    $p = Get-Palette
    $drive = $Drive.ToUpperInvariant()
    $body = @'
<StackPanel>
  <Button x:Name="BrowseDrive" Style="{StaticResource KitGhost}" HorizontalContentAlignment="Stretch" Margin="0,0,0,6"/>
  <Button x:Name="EjectDrive" Style="{StaticResource KitGhost}" HorizontalContentAlignment="Stretch"/>
</StackPanel>
'@
    $window = New-VivacWindow (Get-WindowXaml 'vivac - usb' 390 240 (Get-KitPanelXaml $p 0xE88E $drive $body @(@('Esc', (T 'bt.key.close')))))
    Set-KitDropDown $window
    $window.FindName('Subtitle').Text = T 'bar.disks'
    $browse = $window.FindName('BrowseDrive')
    $browse.Content = New-KitRow $p 0xE8B7 (T 'bar.open_drive')
    $eject = $window.FindName('EjectDrive')
    $eject.Content = New-KitRow $p 0xE8F3 (T 'bar.eject')
    $browse.Add_Click({ $window.Tag = 'browse'; $window.Close() })
    $eject.Add_Click({ $window.Tag = 'eject'; $window.Close() })
    $window.Add_PreviewKeyDown({ param($sender, $eventArgs) if ($eventArgs.Key -eq 'Escape') { $window.Close(); $eventArgs.Handled = $true } })
    if ($NoShow) { return $window }
    if ($Registry) { $Registry['usb'] = $window }
    [void]$window.ShowDialog()
    # The caller performs the action after the panel has closed, so Explorer
    # and the removal status panel can take focus without interrupting it.
    [string]$window.Tag
}

function Set-UsbEjectStatus {
    param($Window, [ValidateSet('Working', 'Done', 'Busy', 'Gone')][string]$State, [string]$Detail = '')
    $context = $Window.Tag
    $context.Working = ($State -eq 'Working')
    $Window.FindName('EjectProgress').Visibility = if ($context.Working) { 'Visible' } else { 'Collapsed' }
    $Window.FindName('EjectMessage').Text = $context.Messages[$State]
    $Window.FindName('EjectDetail').Text = $Detail
    $Window.FindName('CloseEject').IsEnabled = -not $context.Working
}

function Show-UsbEjectStatus {
    param([ValidatePattern('^[A-Za-z]:$')][string]$Drive, [switch]$NoShow)
    Update-SurfaceContext
    $p = Get-Palette
    $drive = $Drive.ToUpperInvariant()
    $body = @'
<StackPanel>
  <TextBlock x:Name="EjectMessage" TextWrapping="Wrap" FontSize="17" Margin="0,0,0,14"/>
  <ProgressBar x:Name="EjectProgress" IsIndeterminate="True" Height="5" Margin="0,0,0,14"/>
  <TextBlock x:Name="EjectDetail" TextWrapping="Wrap" Margin="0,0,0,14"/>
  <Button x:Name="CloseEject" Style="{StaticResource KitButton}" HorizontalAlignment="Right"/>
</StackPanel>
'@
    $window = New-VivacWindow (Get-WindowXaml 'vivac - usb removal' 490 340 (Get-KitPanelXaml $p 0xE8F3 $drive $body))
    # The result must remain visible even if focus moves elsewhere.
    $window.Resources['vivac.keep'] = $true
    $context = @{
        Working = $true; Worker = $null; Pending = $null; Timer = $null
        Messages = @{
            Working = T 'bar.eject_working' @($drive)
            Done = T 'bar.eject_done' @($drive)
            Busy = T 'bar.eject_busy' @($drive)
            Gone = T 'bar.eject_gone' @($drive)
        }
    }
    $window.Tag = $context
    $window.FindName('Subtitle').Text = T 'bar.eject'
    $window.FindName('CloseEject').Content = T 'bar.eject_close'
    $window.FindName('CloseEject').Add_Click({ $window.Close() }.GetNewClosure())
    $window.Add_Closing({ param($sender, $eventArgs) if ($sender.Tag.Working) { $eventArgs.Cancel = $true } })
    $window.Add_PreviewKeyDown({ param($sender, $eventArgs)
        if ($eventArgs.Key -eq 'Escape' -and -not $sender.Tag.Working) { $sender.Close(); $eventArgs.Handled = $true }
    })
    Set-UsbEjectStatus $window Working
    # Building/previews never inspect or eject any drive.
    if ($NoShow) { return $window }

    $updateView = ${function:Set-UsbEjectStatus}
    $usbModule = Join-Path $PSScriptRoot 'Usb.psm1'
    $window.Add_ContentRendered({
        $context.Worker = [PowerShell]::Create()
        [void]$context.Worker.AddScript({ param($modulePath, $letter)
            $ErrorActionPreference = 'Stop'
            if (-not (Test-Path -LiteralPath "$letter\")) { return [pscustomobject]@{ Gone = $true } }
            Import-Module $modulePath -Force
            Remove-VivacUsbDrive -Drive $letter -Confirm:$false
        }).AddArgument($usbModule).AddArgument($drive)
        $context.Pending = $context.Worker.BeginInvoke()
        $context.Timer = New-Object Windows.Threading.DispatcherTimer
        $context.Timer.Interval = [TimeSpan]::FromMilliseconds(150)
        $tickContext = $context; $tickWindow = $window; $tickUpdate = $updateView
        $context.Timer.Add_Tick({
            if (-not $tickContext.Pending.IsCompleted) { return }
            $tickContext.Timer.Stop()
            try {
                $results = @($tickContext.Worker.EndInvoke($tickContext.Pending))
                if ($tickContext.Worker.HadErrors) { throw [string]$tickContext.Worker.Streams.Error[0] }
                if ($results.Count -ne 1) { throw 'No USB removal result was returned.' }
                $result = $results[0]
                if ($result.PSObject.Properties['Gone']) { & $tickUpdate $tickWindow Gone }
                elseif ($result.Success) { & $tickUpdate $tickWindow Done }
                else { & $tickUpdate $tickWindow Busy ('0x{0:X}; veto {1}; {2}' -f $result.Code, $result.Veto, $result.Reason) }
            } catch { & $tickUpdate $tickWindow Busy $_.Exception.Message }
            finally { $tickContext.Worker.Dispose() }
        }.GetNewClosure())
        $context.Timer.Start()
    }.GetNewClosure())
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Show-UsbDriveMenu, Show-UsbEjectStatus, Set-UsbEjectStatus
