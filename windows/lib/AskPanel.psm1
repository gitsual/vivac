# vivac ask, the panel (MOD+Shift+A): a conversation with a local model in a
# column against the right edge of the screen, in the palette. lib/Ask.psm1
# does the talking; this file only draws it.
#
# The request runs on a thread of its own (Start-VivacAskJob) and a timer on
# this one takes the pieces of the answer as they arrive, so the window keeps
# answering keys while a model loads. The answer is text in a read-only box:
# nothing in it is run, and it reaches the clipboard only through Copy answer.
# The conversation lives in this window and goes when it closes; Save writes
# it as Markdown where you choose. Unlike the other surfaces, the panel stays
# when another window takes the focus: you read beside it.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Surfaces.psm1')
Import-Module (Join-Path $PSScriptRoot 'Bridge.psm1')
Import-Module (Join-Path $PSScriptRoot 'Ask.psm1')

# Mode: '' (nothing in it yet), 'clip' (the clipboard's text goes in as
# context with the first question) or 'inbox' (what arrived in
# Downloads\vivac-link, summarised at once).
function Show-Ask([string]$Mode = '', [switch]$NoShow) {
    Update-SurfaceContext
    if (-not $NoShow) { Enter-SingleInstance 'ask' }
    $p = Get-Palette
    $cfg = Get-VivacAskSettings
    $hints = @(@('Enter', (T 'ask.key_send')), @('Shift+Enter', (T 'ask.key_newline')), @('Ctrl+Shift+C', (T 'ask.copy')),
        @('Ctrl+S', (T 'ask.save')), @('Esc', (T 'ask.key_close')))
    $body = @"
<DockPanel>
  <StackPanel DockPanel.Dock="Bottom" Margin="0,10,0,0">
    <TextBox x:Name="Input" AcceptsReturn="True" TextWrapping="Wrap" MinHeight="64" MaxHeight="180" VerticalScrollBarVisibility="Auto"
             Padding="8,6" FontSize="14" Background="#$($p['COLOR_SURFACE'])" Foreground="#$($p['COLOR_FG'])"
             CaretBrush="#$($p['COLOR_ACCENT'])" BorderBrush="#$($p['COLOR_ACCENT'])" BorderThickness="0,0,0,2"/>
    <WrapPanel Margin="0,8,0,0">
      <Button x:Name="Send" Style="{StaticResource KitButton}" Margin="0,0,6,0" Content="$(ConvertTo-XmlText (T 'ask.send'))"/>
      <Button x:Name="Copy" Style="{StaticResource KitGhost}" Margin="0,0,6,0" Content="$(ConvertTo-XmlText (T 'ask.copy'))"/>
      <Button x:Name="Save" Style="{StaticResource KitGhost}" Margin="0,0,6,0" Content="$(ConvertTo-XmlText (T 'ask.save'))"/>
      <Button x:Name="Clear" Style="{StaticResource KitGhost}" Content="$(ConvertTo-XmlText (T 'ask.clear'))"/>
    </WrapPanel>
  </StackPanel>
  <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel x:Name="Turns"/>
  </ScrollViewer>
</DockPanel>
"@
    $window = New-VivacWindow (Get-WindowXaml 'vivac - ask' 520 700 (Get-KitPanelXaml $p 0xE8BD (T 'ask.title') $body $hints))
    # A column at the right edge, under the bar, the height of the work area.
    $area = [Windows.SystemParameters]::WorkArea
    $window.WindowStartupLocation = 'Manual'
    $window.Height = [Math]::Max(400, $area.Height - 30)
    $window.Left = $area.Right - $window.Width - 15
    $window.Top = $area.Top + 15
    $window.Resources['vivac.keep'] = $true
    $subtitle = $window.FindName('Subtitle')
    $subtitle.Text = $cfg.Url
    $inputBox = $window.FindName('Input')
    $turnsPanel = $window.FindName('Turns')
    $scroll = $window.FindName('Scroll')
    $sendButton = $window.FindName('Send')

    # What the handlers share. They run in scopes of their own, so state they
    # change lives in this table rather than in variables.
    $ui = @{
        Endpoint = $null; Model = ''; Turns = (New-Object System.Collections.ArrayList); Context = ''
        Job = $null; JobKind = ''; Box = $null; Waiting = ''; Pending = ''; LastAnswer = ''; Started = $false
    }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(60)

    # One card per turn: who, then the text in a box you can select and copy
    # from but not type into.
    $addCard = {
        param([string]$Who, [string]$Text, [bool]$Mine)
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 10; $card.Padding = '12,8'; $card.Margin = '0,0,0,8'
        if ($Mine) { $card.Background = "#$($p['COLOR_SURFACE_ALT'])" } else { $card.Background = "#$($p['COLOR_SURFACE'])" }
        $stack = New-Object Windows.Controls.StackPanel
        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $Who; $label.FontSize = 11; $label.Margin = '0,0,0,4'
        if ($Mine) { $label.Foreground = "#$($p['COLOR_MUTED'])" } else { $label.Foreground = "#$($p['COLOR_ACCENT'])" }
        [void]$stack.Children.Add($label)
        $box = New-Object Windows.Controls.TextBox
        $box.IsReadOnly = $true; $box.TextWrapping = 'Wrap'; $box.BorderThickness = 0; $box.Background = 'Transparent'
        $box.Foreground = "#$($p['COLOR_FG'])"; $box.CaretBrush = "#$($p['COLOR_ACCENT'])"; $box.FontSize = 14; $box.Padding = '0'
        $box.Text = $Text
        [void]$stack.Children.Add($box)
        $card.Child = $stack
        [void]$turnsPanel.Children.Add($card)
        $scroll.ScrollToEnd()
        $box
    }
    # A line from vivac itself (the model it took, an error, a copy done).
    $notice = {
        param([string]$Text)
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Text; $t.TextWrapping = 'Wrap'; $t.FontSize = 12; $t.Margin = '2,0,2,8'
        $t.Foreground = "#$($p['COLOR_MUTED'])"
        [void]$turnsPanel.Children.Add($t)
        $scroll.ScrollToEnd()
    }
    $startJob = {
        param([string]$Kind, [object[]]$Messages)
        $ui.JobKind = $Kind
        $ui.Job = Start-VivacAskJob $Kind $ui.Endpoint $cfg.Model $Messages $cfg.Timeout
        $sendButton.Content = T 'ask.stop'
        $timer.Start()
    }
    $send = {
        param([string]$Question)
        if ($ui.Job -or -not $ui.Endpoint) { return }
        $Question = $Question.Trim()
        if (-not $Question) { return }
        $inputBox.Clear()
        # No model yet (Ollama was not running when the panel opened): look
        # for one first, then ask.
        if (-not $ui.Model) { $ui.Pending = $Question; & $startJob 'models' @(); return }
        $content = $Question
        if ($ui.Context -and -not $ui.Turns.Count) { $content = $ui.Context + "`n`n" + $Question }
        [void]$ui.Turns.Add(@{ role = 'user'; content = $content })
        [void](& $addCard (T 'ask.you') $Question $true)
        $ui.Waiting = T 'ask.thinking'
        $ui.Box = & $addCard $ui.Model $ui.Waiting $false
        & $startJob 'chat' (Get-VivacAskMessages $ui.Turns.ToArray())
    }
    $drain = {
        $piece = $null
        $any = $false
        while ($ui.Job.Queue.TryDequeue([ref]$piece)) {
            if ($ui.Box.Text -ceq $ui.Waiting) { $ui.Box.Text = '' }
            $ui.Box.AppendText($piece)
            $any = $true
        }
        if ($any) { $scroll.ScrollToEnd() }
    }
    $timer.Add_Tick({
            $job = $ui.Job
            if (-not $job) { $timer.Stop(); return }
            if ($ui.JobKind -eq 'chat') { & $drain }
            if (-not $job.Done) { return }
            # Done is set after the last piece, so this pass takes the rest.
            if ($ui.JobKind -eq 'chat') { & $drain }
            $timer.Stop()
            $ui.Job = $null
            $sendButton.Content = T 'ask.send'
            try { $job.Shell.Dispose() } catch { }
            if ($ui.JobKind -eq 'models') {
                if ($job.Error) { & $notice $job.Error; return }
                $ui.Model = $job.Result.Name
                $subtitle.Text = "$($ui.Model) - $($cfg.Url)"
                if ($job.Result.Chosen) { & $notice (T 'ask.model_auto' @($ui.Model)) }
                if ($ui.Pending) { $q = $ui.Pending; $ui.Pending = ''; & $send $q }
                return
            }
            if ($job.Stop) {
                # What arrived so far stays in the conversation, marked as cut short.
                $partial = $ui.Box.Text
                if ($partial -ceq $ui.Waiting) { $partial = '' }
                $ui.Box.Text = ($partial + ' [' + (T 'ask.stopped') + ']').Trim()
                [void]$ui.Turns.Add(@{ role = 'assistant'; content = $ui.Box.Text })
            } elseif ($job.Error) {
                if ($ui.Box.Text -ceq $ui.Waiting) { $ui.Box.Text = $job.Error } else { $ui.Box.AppendText("`n`n" + $job.Error) }
                $ui.Turns.RemoveAt($ui.Turns.Count - 1)
            } else {
                $ui.LastAnswer = [string]$job.Result
                if (-not $ui.LastAnswer) { $ui.Box.Text = '' }
                [void]$ui.Turns.Add(@{ role = 'assistant'; content = $ui.LastAnswer })
            }
        })

    $copyAnswer = {
        if (-not $ui.LastAnswer) { & $notice (T 'ask.nothing_to_copy'); return }
        try { [Windows.Clipboard]::SetText($ui.LastAnswer); & $notice (T 'ask.copied') } catch { & $notice (T 'ask.copy_failed') }
    }
    $saveTalk = {
        if (-not $ui.Turns.Count) { & $notice (T 'ask.nothing_to_save'); return }
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Title = T 'ask.save'
        $dialog.FileName = 'vivac-ask-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.md'
        $dialog.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        $dialog.Filter = 'Markdown (*.md)|*.md'
        $dialog.OverwritePrompt = $true
        if (-not $dialog.ShowDialog($window)) { return }
        try {
            Save-VivacAskConversation $dialog.FileName (ConvertTo-VivacAskMarkdown $ui.Model $ui.Turns.ToArray()) -Replace
            & $notice (T 'ask.saved' @($dialog.FileName))
        } catch { & $notice (T 'ask.save_failed' @($_.Exception.Message)) }
    }
    $clearTalk = {
        if ($ui.Job) { return }
        $ui.Turns.Clear(); $ui.Context = ''; $ui.LastAnswer = ''
        $turnsPanel.Children.Clear()
        & $notice (T 'ask.cleared')
    }

    # The first time the panel is on screen: check where it may talk to, take
    # the context the mode asks for, and find the model, on the other thread.
    $begin = {
        if ($ui.Started) { return }
        $ui.Started = $true
        [void]$inputBox.Focus()
        try { $ui.Endpoint = Get-VivacAskEndpoint $cfg.Url $cfg.AllowLan } catch {
            & $notice $_.Exception.Message
            $inputBox.IsEnabled = $false; $sendButton.IsEnabled = $false
            return
        }
        if ($Mode -eq 'clip') {
            $text = ''
            try { $text = [Windows.Clipboard]::GetText() } catch { }
            $clip = Get-VivacAskClipContext $text
            if (-not $clip) { & $notice (T 'ask.clip_empty') } else {
                $ui.Context = $clip.Text
                if ($clip.Cut) { & $notice (T 'ask.clip_cut' @($clip.Limit)) }
                & $notice (T 'ask.clip_loaded' @($clip.Size))
            }
        } elseif ($Mode -eq 'inbox') {
            try {
                $ui.Context = Get-VivacAskInboxContext (Get-VivacLinkInbox)
                $ui.Pending = T 'ask.inbox_request'
            } catch { & $notice $_.Exception.Message }
        }
        & $startJob 'models' @()
    }

    $sendButton.Add_Click({ if ($ui.Job) { Stop-VivacAskJob $ui.Job } else { & $send $inputBox.Text } })
    $window.FindName('Copy').Add_Click({ & $copyAnswer })
    $window.FindName('Save').Add_Click({ & $saveTalk })
    $window.FindName('Clear').Add_Click({ & $clearTalk })
    $window.Add_PreviewKeyDown({
            param($s, $ev)
            $k = [string]$ev.Key
            $mods = [Windows.Input.Keyboard]::Modifiers
            $ctrl = [bool]($mods -band [Windows.Input.ModifierKeys]::Control)
            $shift = [bool]($mods -band [Windows.Input.ModifierKeys]::Shift)
            if ($k -eq 'Escape') { $window.Close(); $ev.Handled = $true; return }
            if ($k -eq 'Return' -and -not $shift -and $inputBox.IsKeyboardFocusWithin) { & $send $inputBox.Text; $ev.Handled = $true; return }
            if ($k -eq 'C' -and $ctrl -and $shift) { & $copyAnswer; $ev.Handled = $true; return }
            if ($k -eq 'S' -and $ctrl) { & $saveTalk; $ev.Handled = $true; return }
        })
    $window.Add_ContentRendered({ & $begin })
    # Built without being shown (the gates), the window outlives this
    # function's variables; closing it then has nothing to stop.
    $window.Add_Closed({ try { $timer.Stop(); Stop-VivacAskJob $ui.Job } catch { } })
    if ($NoShow) { return $window }
    [void]$window.ShowDialog()
}

Export-ModuleMember -Function Show-Ask
