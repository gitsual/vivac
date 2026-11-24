# A panel that opens when the pointer rests on its bar button, and the one
# rule that closes it again. The Arch side keeps the same rule in
# linux/lib/vivacpanel/kit.py (HoverClose) and the bar's own popups in
# static/zebar/vivac/hover-rule.js; the numbers are the same on all three.
#
#   rest on the button 300 ms   the panel opens (the bar times this)
#   button left, panel never entered   closes 500 ms later
#   panel left                         closes 350 ms later
#   back into the panel, or resting on the button again   cancels the close
#   a click or a key in the panel      pins it: only Esc, a click outside or
#                                      losing the focus close it from then on
#
# The rule knows no clock: every call is given "now" in milliseconds, so a
# test drives it with a fake one and the window with a real one.

Set-StrictMode -Version 2.0

class VivacHoverClose {
    [int]$ButtonMs = 500
    [int]$PanelMs = 350
    [bool]$Pinned = $false
    [bool]$PointerInside = $false
    [bool]$ButtonHot = $false
    # When the panel is due to close; $null when nothing is pending.
    [object]$Deadline = $null

    [void] ButtonRested([long]$now) { $this.ButtonHot = $true; $this.Deadline = $null }
    [void] ButtonLeft([long]$now) {
        $this.ButtonHot = $false
        # The pointer can already be in the panel when this arrives (it
        # crossed the gap and the verb came through the pipe a moment later).
        if (-not $this.Pinned -and -not $this.PointerInside -and $null -eq $this.Deadline) { $this.Deadline = $now + $this.ButtonMs }
    }
    [void] PointerIn([long]$now) { $this.PointerInside = $true; $this.Deadline = $null }
    [void] PointerOut([long]$now) {
        $this.PointerInside = $false
        if (-not $this.Pinned) { $this.Deadline = $now + $this.PanelMs }
    }
    [void] Pin() { $this.Pinned = $true; $this.Deadline = $null }
    # True once, when the panel is due to close.
    [bool] Tick([long]$now) {
        if ($this.Pinned -or $null -eq $this.Deadline) { return $false }
        return $now -ge [long]$this.Deadline
    }
}

function New-VivacHoverClose { New-Object VivacHoverClose }

# How long the pointer must rest on a button before its panel opens. The bar
# (hover.js) times it; the number lives here so the three sides name one.
function Get-VivacHoverRestMs { 300 }

# A monotonic clock in milliseconds (Environment.TickCount wraps).
function Get-VivacHoverNow { [long]([Diagnostics.Stopwatch]::GetTimestamp() * 1000 / [Diagnostics.Stopwatch]::Frequency) }

# The verbs the bar sends: "hover <panel>" when the pointer has rested on a
# button and "hover-leave <panel>" when it goes. Only the panels that exist
# as resident windows are named, so the pipe cannot be made to open anything
# else this way; usb carries the drive (usb:G:) its menu is about.
function Resolve-VivacHoverVerb([string]$Text) {
    $m = [regex]::Match($Text, '^hover(-leave)? (network|bluetooth|sound|security|theme|power|updates|usb:[a-z]:)$')
    if (-not $m.Success) { return $null }
    $panel = $m.Groups[2].Value
    $r = @{ Kind = 'rest'; Verb = $panel; Key = $panel; Drive = '' }
    if ($m.Groups[1].Success) { $r.Kind = 'leave' }
    if ($panel -like 'usb:*') { $r.Verb = 'usb'; $r.Key = 'usb'; $r.Drive = $panel.Substring(4).ToUpperInvariant() }
    $r
}

# Verbs that share a window share its slot in the host's registry.
function Get-VivacHoverKey([string]$Verb) {
    switch ($Verb) { 'phone' { 'menu' } 'switch' { 'power' } default { $Verb } }
}

# What a hover verb does to the host's windows: 'open' (the caller builds the
# panel, in hover mode), 'rested', 'left' or 'ignored'. $Open maps a panel to
# its window, $States to the rule of those opened by hover; a panel a click
# opened has no state, which is what keeps hover from ever closing it.
function Step-VivacHover($Verb, [hashtable]$Open, [hashtable]$States, [long]$Now) {
    $key = $Verb.Key
    $window = $null
    if ($Open.ContainsKey($key)) { $window = $Open[$key] }
    $live = $window -and $window.IsVisible
    if (-not $live) { $States.Remove($key) }
    if ($Verb.Kind -eq 'rest') {
        if (-not $live) { return 'open' }
        if ($States.ContainsKey($key)) { $States[$key].ButtonRested($Now); return 'rested' }
        return 'ignored'
    }
    if ($live -and $States.ContainsKey($key)) { $States[$key].ButtonLeft($Now); return 'left' }
    'ignored'
}

# A click on a bar button whose panel is open by hover pins it, instead of
# toggling it closed; a second click then toggles as it always did.
function Step-VivacClick([string]$Key, [hashtable]$Open, [hashtable]$States) {
    $window = $null
    if ($Open.ContainsKey($Key)) { $window = $Open[$Key] }
    if ($window -and $window.IsVisible -and $States.ContainsKey($Key) -and -not $States[$Key].Pinned) {
        $States[$Key].Pin()
        return 'pinned'
    }
    'toggle'
}

Export-ModuleMember -Function New-VivacHoverClose, Get-VivacHoverRestMs, Get-VivacHoverNow, Resolve-VivacHoverVerb, Get-VivacHoverKey, Step-VivacHover, Step-VivacClick
