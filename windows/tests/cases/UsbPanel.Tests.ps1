Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\UsbPanel.psm1') -Force

Case 'USB removal stays visible and cannot be dismissed while working' {
    $w = Show-UsbEjectStatus -Drive G: -NoShow
    Assert-True $w.Resources['vivac.keep'] 'keep the result visible after focus changes'
    Assert-True $w.Tag.Working 'initial state is working'
    Assert-True (-not $w.FindName('CloseEject').IsEnabled) 'no closing during removal'
    Assert-Equal 'Visible' $w.FindName('EjectProgress').Visibility
    Assert-True ($null -eq $w.Tag.Worker) 'building a preview never starts device removal'
    Set-UsbEjectStatus $w Gone
    $w.Close()
}
Case 'USB success, veto and missing drive have distinct persistent outcomes' {
    $w = Show-UsbEjectStatus -Drive G: -NoShow
    $messages = @()
    foreach ($state in 'Done', 'Busy', 'Gone') {
        Set-UsbEjectStatus $w $state 'test detail'
        Assert-True (-not $w.Tag.Working) 'operation finished'
        Assert-True $w.FindName('CloseEject').IsEnabled 'the user can acknowledge the result'
        Assert-Equal 'Collapsed' $w.FindName('EjectProgress').Visibility
        Assert-Equal 'test detail' $w.FindName('EjectDetail').Text
        $messages += $w.FindName('EjectMessage').Text
    }
    Assert-Equal 3 @($messages | Select-Object -Unique).Count 'distinct messages'
    $w.Close()
}
Complete-Cases
