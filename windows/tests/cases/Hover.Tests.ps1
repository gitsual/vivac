# Opening a panel by resting the pointer on its bar button. The rule that
# closes it again lives in one place (lib\Hover.psm1; the bar's popups have
# the same rule in static\zebar\vivac\hover-rule.js), and these cases pin
# the contract the Arch side keeps: 300 ms to open, 500 ms to close after
# the button, 350 ms after the panel, a click or key pins.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Import-Module (Join-Path $root 'lib\Hover.psm1') -Force
$zebar = Join-Path $root 'static\zebar\vivac'
$hasNode = [bool](Get-Command node -CommandType Application -ErrorAction SilentlyContinue)

# Runs an ES module script under Node and returns its JSON output; a script
# that fails is an error, never an empty (and so vacuously passing) result.
function Invoke-Mjs([string]$Body) {
    $f = Join-Path ([IO.Path]::GetTempPath()) ('vivac-hover-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.mjs')
    [IO.File]::WriteAllText($f, $Body.Replace('@ZEBAR@', ([Uri]$zebar).AbsoluteUri))
    try {
        $out = & node $f 2>&1
        if ($LASTEXITCODE -ne 0) { throw "node failed: $($out -join ' ')" }
        $out | ConvertFrom-Json
    } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- the rule

Case 'the button left, the panel never entered: it closes 500 ms later, not before' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0)
    $h.ButtonLeft(1000)
    Assert-True (-not $h.Tick(1499)) 'closed early'
    Assert-True $h.Tick(1500) 'did not close at 500 ms'
}
Case 'the pointer in the panel keeps it open however long it stays' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0)
    $h.PointerIn(100)
    $h.ButtonLeft(110)
    Assert-True (-not $h.Tick(60000)) 'closed with the pointer inside'
}
Case 'the pointer out of the panel: it closes 350 ms later' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0)
    $h.PointerIn(100)
    $h.PointerOut(2000)
    Assert-True (-not $h.Tick(2349)) 'closed early'
    Assert-True $h.Tick(2350) 'did not close at 350 ms'
}
Case 'back into the panel before the 350 ms cancels the close' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0); $h.PointerIn(100); $h.PointerOut(2000)
    $h.PointerIn(2200)
    Assert-True (-not $h.Tick(9000)) 'closed after the pointer came back'
}
Case 'resting on the button again cancels the pending close' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0); $h.PointerIn(100); $h.PointerOut(2000)
    $h.ButtonRested(2300)
    Assert-True (-not $h.Tick(9000)) 'closed after the button was rested on again'
    $h.ButtonLeft(9000)
    Assert-True $h.Tick(9500) 'the button leaving again does not close it'
}
Case 'the button leaving after the pointer entered the panel (messages cross) closes nothing' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0)
    $h.PointerIn(50)
    $h.ButtonLeft(80)
    Assert-True (-not $h.Tick(5000)) 'a late button-left closed a panel the pointer is in'
}
Case 'a click or a key in the panel pins it: nothing closes it by hover any more' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0); $h.PointerIn(100)
    $h.Pin()
    Assert-True $h.Pinned 'not pinned'
    $h.PointerOut(1000); $h.ButtonLeft(1001)
    Assert-True (-not $h.Tick(99999)) 'a pinned panel closed by hover'
}
Case 'a panel pinned while a close was pending is not closed' {
    $h = New-VivacHoverClose
    $h.ButtonRested(0); $h.ButtonLeft(100)
    $h.Pin()
    Assert-True (-not $h.Tick(5000)) 'the pending close survived the pin'
}
Case 'the numbers are the contract: 500 after the button, 350 after the panel' {
    $h = New-VivacHoverClose
    Assert-Equal 500 $h.ButtonMs
    Assert-Equal 350 $h.PanelMs
    Assert-Equal 300 (Get-VivacHoverRestMs)
}

# ------------------------------------------------------------ the verbs

Case 'hover and hover-leave verbs name a panel; anything else is not one' {
    $v = Resolve-VivacHoverVerb 'hover sound'
    Assert-Equal 'rest' $v.Kind; Assert-Equal 'sound' $v.Verb; Assert-Equal 'sound' $v.Key
    $v = Resolve-VivacHoverVerb 'hover-leave network'
    Assert-Equal 'leave' $v.Kind; Assert-Equal 'network' $v.Verb
    $v = Resolve-VivacHoverVerb 'hover usb:e:'
    Assert-Equal 'usb' $v.Key; Assert-Equal 'E:' $v.Drive
    foreach ($p in 'bluetooth', 'security', 'theme', 'power', 'updates') { Assert-Equal $p (Resolve-VivacHoverVerb "hover $p").Verb }
    foreach ($bad in 'hover', 'hover menu', 'hover clipboard', 'hover lock', 'hover quit', 'hover phone', 'hover-leave help', 'hover sound now', 'sound', 'hover usb:12') {
        Assert-True ($null -eq (Resolve-VivacHoverVerb $bad)) "'$bad' is not a hover verb"
    }
}

function New-FakeWindow([bool]$Visible) {
    $w = [pscustomobject]@{ IsVisible = $Visible; Closed = 0 }
    $w | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Closed++; $this.IsVisible = $false }
    $w
}

Case 'hover on a closed panel asks the host to open it in hover mode' {
    $open = @{}; $states = @{}
    $r = Resolve-VivacHoverVerb 'hover sound'
    Assert-Equal 'open' (Step-VivacHover $r $open $states 0)
}
Case 'hover on a panel open by hover is only the button resting again' {
    $open = @{ sound = (New-FakeWindow $true) }; $states = @{ sound = (New-VivacHoverClose) }
    $states.sound.ButtonRested(0); $states.sound.PointerOut(10)
    Assert-Equal 'rested' (Step-VivacHover (Resolve-VivacHoverVerb 'hover sound') $open $states 100)
    Assert-True (-not $states.sound.Tick(9999)) 'the pending close was not cancelled'
}
Case 'hover on a panel a click opened changes nothing (it is pinned from the start)' {
    $open = @{ sound = (New-FakeWindow $true) }; $states = @{}
    Assert-Equal 'ignored' (Step-VivacHover (Resolve-VivacHoverVerb 'hover sound') $open $states 0)
    Assert-Equal 0 $open.sound.Closed
}
Case 'hover-leave starts the 500 ms close of a panel open by hover; none for a pinned or absent one' {
    $open = @{ sound = (New-FakeWindow $true) }; $states = @{ sound = (New-VivacHoverClose) }
    $states.sound.ButtonRested(0)
    Assert-Equal 'left' (Step-VivacHover (Resolve-VivacHoverVerb 'hover-leave sound') $open $states 1000)
    Assert-True $states.sound.Tick(1500) 'the close did not start'
    Assert-Equal 'ignored' (Step-VivacHover (Resolve-VivacHoverVerb 'hover-leave sound') @{} @{} 0)
    Assert-Equal 'ignored' (Step-VivacHover (Resolve-VivacHoverVerb 'hover-leave sound') @{ sound = (New-FakeWindow $true) } @{} 0)
}
Case 'a stale state of a window that is gone does not hold the next opening' {
    $open = @{ sound = (New-FakeWindow $false) }; $states = @{ sound = (New-VivacHoverClose) }
    Assert-Equal 'open' (Step-VivacHover (Resolve-VivacHoverVerb 'hover sound') $open $states 0)
    Assert-True (-not $states.ContainsKey('sound')) 'the stale state stayed'
}
Case 'the button clicked while the panel is open by hover pins it; the next click closes it' {
    $open = @{ sound = (New-FakeWindow $true) }; $states = @{ sound = (New-VivacHoverClose) }
    $states.sound.ButtonRested(0)
    Assert-Equal 'pinned' (Step-VivacClick 'sound' $open $states)
    Assert-True $states.sound.Pinned 'not pinned'
    Assert-Equal 'toggle' (Step-VivacClick 'sound' $open $states)
}
Case 'a click on a panel that is closed, or open by a click, is the old toggle' {
    Assert-Equal 'toggle' (Step-VivacClick 'sound' @{} @{})
    Assert-Equal 'toggle' (Step-VivacClick 'sound' @{ sound = (New-FakeWindow $true) } @{})
}
Case 'phone shares the menu window, switch the power one, for the click rule' {
    Assert-Equal 'menu' (Get-VivacHoverKey 'phone')
    Assert-Equal 'power' (Get-VivacHoverKey 'switch')
    Assert-Equal 'sound' (Get-VivacHoverKey 'sound')
}

# ----------------------------------------------------- the host and panels

$daemon = [IO.File]::ReadAllText((Join-Path $root 'bin\vivac-daemon.ps1'))
$surfaces = [IO.File]::ReadAllText((Join-Path $root 'lib\Surfaces.psm1'))
Case 'the host routes hover verbs through the rule and a click through the pin check' {
    Assert-True ($daemon -match 'Resolve-VivacHoverVerb') 'the host never reads a hover verb'
    Assert-True ($daemon -match 'Step-VivacHover') 'the host does not apply the rule'
    Assert-True ($daemon -match 'Step-VivacClick') 'a click does not pin a hover panel'
    Assert-True ($daemon -match 'Set-VivacHoverNext') 'the opening panel is not told it is a hover one'
}
Case 'every panel window gets its pointer and key hooks in the one place windows are made' {
    $fn = [regex]::Match($surfaces, '(?s)function New-VivacWindow.*?\n\}\n').Value
    Assert-True ($fn -match 'Connect-VivacHover') 'New-VivacWindow does not hook the hover rule'
}
Case 'a window made for hover is wired to the pointer, keys and a timer' {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
    $state = New-VivacHoverClose
    Set-VivacHoverNext $state
    $w = New-VivacWindow '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="40" Height="40"><Border Background="Red"/></Window>'
    Assert-True ($w.Resources['vivac.hover'] -eq $state) 'the state is not on the window'
    Assert-True ($null -ne $w.Resources['vivac.hoverTimer']) 'no timer'
    $other = New-VivacWindow '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="40" Height="40"><Border Background="Red"/></Window>'
    Assert-True ($null -eq $other.Resources['vivac.hover']) 'the hover state leaked to the next window'
}

# ------------------------------------------------------------ the bar

$bar = [IO.File]::ReadAllText((Join-Path $zebar 'bar.js'))
$pack = [IO.File]::ReadAllText((Join-Path $zebar 'zpack.json'))

Case 'the bar maps its buttons to panels as the Arch bar does, and the phone and workspaces to none' {
    if (-not $hasNode) { Write-Host '  (node not installed: skipped)'; return }
    $js = @"
import { panelFor } from '@ZEBAR@/hover.js';
const want = { mute: 'sound', network: 'network', bluetooth: 'bluetooth', security: 'security', theme: 'theme', power: 'power', updates: 'updates', sys: 'system', sysgauge: 'system', eject: 'usb:G:' };
const out = {};
for (const [act, p] of Object.entries(want)) out[act] = panelFor(act, { drive: 'G:' }) === p;
out.phone = panelFor('phone', {}) === null;
out.sesiones = panelFor('sesiones', {}) === null;
out.clock = panelFor('clock', {}) === 'calendar';
out.weather = panelFor('weather', {}) === 'forecast';
console.log(JSON.stringify(out));
"@
    $r = Invoke-Mjs $js
    foreach ($p in $r.PSObject.Properties) { Assert-True $p.Value "panelFor wrong for $($p.Name)" }
}
Case 'a button that opens a panel on hover keeps no tooltip; the others keep theirs' {
    if (-not $hasNode) { Write-Host '  (node not installed: skipped)'; return }
    $js = @"
import { opensPanel } from '@ZEBAR@/hover.js';
console.log(JSON.stringify({ a: opensPanel('network'), b: opensPanel('phone'), c: opensPanel('sesiones'), d: opensPanel('sysgauge') }));
"@
    $r = Invoke-Mjs $js
    Assert-True $r.a 'network keeps its tooltip'
    Assert-True (-not $r.b) 'phone lost its tooltip'
    Assert-True (-not $r.c) 'sesiones lost its tooltip'
    Assert-True $r.d 'a gauge keeps its tooltip'
    Assert-True ($bar -match "removeAttribute\('title'\)") 'bar.js never strips a panel button''s title'
    Assert-True ($bar -match 'opensPanel\(') 'bar.js does not ask which buttons have a panel'
}
Case 'resting 300 ms opens, passing over opens nothing, leaving tells the panel' {
    if (-not $hasNode) { Write-Host '  (node not installed: skipped)'; return }
    $js = @"
import { createHoverIntent } from '@ZEBAR@/hover.js';
let now = 0; const timers = []; const log = [];
const setTimer = (fn, ms) => { timers.push({ at: now + ms, fn }); return timers.length - 1; };
const clearTimer = (id) => { if (timers[id]) timers[id] = null; };
const advance = (ms) => { const to = now + ms; for (;;) { const t = timers.filter(Boolean).filter((x) => x.at <= to).sort((a, b) => a.at - b.at)[0]; if (!t) break; now = t.at; timers[timers.indexOf(t)] = null; t.fn(); } now = to; };
const h = createHoverIntent({ setTimer, clearTimer, onRest: (k) => log.push('rest ' + k), onLeave: (k) => log.push('leave ' + k) });
h.target('sound'); advance(299); h.target(null); advance(1000);
log.push('--');
h.target('sound'); advance(300); h.target('network'); advance(299); h.target(null);
log.push('--');
h.target('theme'); h.click(); advance(1000); h.target(null);
console.log(JSON.stringify(log));
"@
    $r = Invoke-Mjs $js
    # pass over: nothing. rest on sound opens; moving to network tells sound it was left; network not rested in 299.
    # a click before the rest opens nothing by hover.
    Assert-Equal @('--', 'rest sound', 'leave sound', '--') $r
}
Case 'the bar sends hover verbs to the host pipe only, never starts a panel for them' {
    Assert-True ($bar -match "import \{[^}]*\} from './hover\.js'") 'bar.js does not import hover.js'
    Assert-True ($bar -match 'hostSay\(`hover ') 'no hover verb is sent'
    Assert-True ($bar -match '/c echo \$\{line\}>\\\\\\\\\.\\\\pipe\\\\') 'hover verbs do not go to the pipe'
    Assert-True ($bar -notmatch '(?s)const hostSay.{0,200}conhost') 'a hover verb may start a process'
    Assert-True ($bar -match 'hover-leave') 'no hover-leave verb is sent'
    $grants = @((ConvertFrom-Json $pack).widgets[0].privileges.shellCommands | Where-Object { $_.argsRegex -like '^/c echo (hover|hover-leave)*' })
    Assert-Equal 1 $grants.Count 'zpack.json grants no hover command (or more than one)'
    Assert-Equal 'cmd.exe' $grants[0].program
    $re = $grants[0].argsRegex
    foreach ($ok in '/c echo hover sound>\\.\pipe\vivac-tester 2>nul', '/c echo hover-leave network>\\.\pipe\vivac-tester 2>nul', '/c echo hover usb:G:>\\.\pipe\vivac-tester 2>nul') {
        Assert-True ($ok -match $re) "not granted: $ok"
    }
    foreach ($no in '/c echo hover menu>\\.\pipe\vivac-tester 2>nul', '/c echo hover sound & calc>\\.\pipe\vivac-tester 2>nul') {
        Assert-True ($no -notmatch $re) "granted: $no"
    }
}

# ------------------------------------------------- Wi-Fi and Ethernet tabs

Case 'the network verbs carry the tab, for hover and for a click' {
    $v = Resolve-VivacHoverVerb 'hover network ethernet'
    Assert-Equal 'rest' $v.Kind; Assert-Equal 'network' $v.Key; Assert-Equal 'ethernet' $v.Tab
    Assert-Equal 'wifi' (Resolve-VivacHoverVerb 'hover-leave network wifi').Tab
    Assert-Equal '' (Resolve-VivacHoverVerb 'hover network').Tab
    Assert-True ($null -eq (Resolve-VivacHoverVerb 'hover network bogus')) 'a made-up tab was accepted'
    Assert-True ($null -eq (Resolve-VivacHoverVerb 'hover sound wifi')) 'a tab on a panel without tabs'
    $c = Resolve-VivacPanelTab 'network wifi'
    Assert-Equal 'network' $c.Verb; Assert-Equal 'wifi' $c.Tab
    $c = Resolve-VivacPanelTab 'sound'
    Assert-Equal 'sound' $c.Verb; Assert-Equal '' $c.Tab
    Assert-Equal 'network x' (Resolve-VivacPanelTab 'network x').Verb
}
Case 'resting on the other pill switches an open network panel, hover-opened or not' {
    $eth = Resolve-VivacHoverVerb 'hover network ethernet'
    $open = @{ network = (New-FakeWindow $true) }; $states = @{ network = (New-VivacHoverClose) }
    $states.network.ButtonRested(0); $states.network.ButtonLeft(10)
    Assert-Equal 'switch' (Step-VivacHover $eth $open $states 100)
    Assert-True (-not $states.network.Tick(9999)) 'the switch did not cancel the pending close'
    Assert-Equal 'switch' (Step-VivacHover $eth @{ network = (New-FakeWindow $true) } @{} 0)
    Assert-Equal 'rested' (Step-VivacHover (Resolve-VivacHoverVerb 'hover network') $open $states 100)
    Assert-Equal 'open' (Step-VivacHover $eth @{} @{} 0)
}
Case 'the bar puts the tab on both network pills, and hover and click carry it' {
    $js = [IO.File]::ReadAllText((Join-Path $zebar 'bar.js'))
    Assert-True ($js -match 'data-act="network" data-tab="\$\{tab\}"') 'the pills carry no tab'
    Assert-True ($js -match "launch\(act === 'network'") 'a click does not carry the tab'
    if ($hasNode) {
        $r = Invoke-Mjs @"
import { panelFor, verbOf } from '@ZEBAR@/hover.js';
console.log(JSON.stringify([panelFor('network', { tab: 'ethernet' }), panelFor('network', {}), verbOf('network:wifi'), verbOf('usb:G:'), verbOf('sound')]));
"@
        Assert-Equal @('network:ethernet', 'network', 'network wifi', 'usb:G:', 'sound') $r
    }
    $cmds = (ConvertFrom-Json $pack).widgets[0].privileges.shellCommands
    $click = ($cmds | Where-Object { $_.program -eq 'cmd.exe' -and $_.argsRegex -match 'conhost' }).argsRegex
    $line = '/c echo network ethernet>\\.\pipe\vivac-x 2>nul || conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\x\bin\vivac.ps1 network ethernet'
    Assert-True ($line -match $click) 'the click with a tab is not granted'
    Assert-True (($line -replace 'ethernet', 'bogus') -notmatch $click) 'a made-up tab is granted'
    $hover = ($cmds | Where-Object { $_.argsRegex -like '^/c echo (hover|hover-leave)*' }).argsRegex
    Assert-True ('/c echo hover network wifi>\\.\pipe\vivac-x 2>nul' -match $hover) 'hover with a tab is not granted'
}
Case 'a network panel can be switched to a tab by the host, and opened on one' {
    $net = [IO.File]::ReadAllText((Join-Path $root 'lib\Network.psm1'))
    Assert-True ($net -match "Resources\['vivac\.setTab'\]") 'Show-Network does not expose its tab switch'
    Assert-True ($daemon -match 'vivac\.setTab') 'the host never switches the tab'
    Assert-True ($daemon -match '(?s)\$netArgs\.Tab = \$tab.{0,40}Show-Network @netArgs') 'the host does not open on the tab'
}

# ------------------------------------- verbs that arrive while a panel is open

# Found with a real pointer in the VM: the host's 30 ms timer does not tick
# again while a panel is open (a DispatcherTimer does not re-enter its own
# handler), so a hover-leave, a click or a tab switch sat in the queue until
# the panel closed. An open panel's own timer therefore serves the verbs that
# concern open panels.
Case 'while a panel is open, hover verbs and the verbs of an open panel are served at once; others wait' {
    $open = @{ sound = (New-FakeWindow $true); help = (New-FakeWindow $false) }
    Assert-True (Test-VivacPumpVerb 'hover sound' $open) 'hover on an open panel'
    Assert-True (Test-VivacPumpVerb 'hover-leave sound' $open) 'hover-leave'
    Assert-True (Test-VivacPumpVerb 'hover network wifi' $open) 'hover on a panel that is not open yet'
    Assert-True (Test-VivacPumpVerb 'sound' $open) 'the click that pins or closes an open panel'
    Assert-True (-not (Test-VivacPumpVerb 'help' $open)) 'a verb for a panel that is closed waits'
    Assert-True (-not (Test-VivacPumpVerb 'menu' $open)) 'a menu key waits'
    Assert-True (-not (Test-VivacPumpVerb 'lock' $open)) 'lock waits'
    Assert-True (-not (Test-VivacPumpVerb 'quit' $open)) 'quit waits'
    $open.network = New-FakeWindow $true
    Assert-True (Test-VivacPumpVerb 'network ethernet' $open) 'a click with a tab on an open panel'
}
Case 'every window is served by the pump, in the one place windows are made' {
    $fn = [regex]::Match($surfaces, '(?s)function New-VivacWindow.*?\n\}\n').Value
    Assert-True ($fn -match 'Start-VivacWindowTimer') 'New-VivacWindow starts no timer'
    Assert-True ($surfaces -match 'function Set-VivacHoverPump') 'no pump can be set'
    Assert-True ($daemon -match 'Set-VivacHoverPump') 'the host sets no pump'
    Assert-True ($daemon -match 'Test-VivacPumpVerb') 'the host does not choose the verbs to serve'
}

# ------------------------------------------------- the Zebar popups' rule

Case 'the popups'' rule (hover-rule.js) is the same contract as the host''s' {
    if (-not $hasNode) { Write-Host '  (node not installed: skipped)'; return }
    $js = @"
import { createHoverClose } from '@ZEBAR@/hover-rule.js';
const r = [];
let h = createHoverClose(); h.buttonRested(0); h.buttonLeft(1000);
r.push(!h.due(1499), h.due(1500));
h = createHoverClose(); h.buttonRested(0); h.pointerIn(10); h.buttonLeft(20);
r.push(!h.due(60000)); h.pointerOut(2000); r.push(!h.due(2349), h.due(2350));
h.pointerIn(2200); r.push(!h.due(2350 + 9000));
h = createHoverClose(); h.buttonRested(0); h.pointerIn(1); h.pointerOut(2000); h.buttonRested(2300); r.push(!h.due(9000));
h = createHoverClose(); h.buttonRested(0); h.buttonLeft(10); h.pin(); r.push(!h.due(99999), h.pinned);
console.log(JSON.stringify(r));
"@
    $r = Invoke-Mjs $js
    for ($i = 0; $i -lt $r.Count; $i++) { Assert-True $r[$i] "check $i of the popup rule failed" }
}
Case 'calendar, forecast and the system panel close by the rule, and a pinned one by Esc or blur' {
    $popup = [IO.File]::ReadAllText((Join-Path $zebar 'popup.js'))
    Assert-True ($popup -match "from './hover-rule\.js'") 'popup.js does not use the shared rule'
    Assert-True ($popup -match 'export function closeByHover') 'no closeByHover'
    Assert-True ([IO.File]::ReadAllText((Join-Path $zebar 'system.js')) -match "closeByHover\('system'") 'the system panel does not use it'
    foreach ($f in 'calendar.js', 'forecast.js') {
        Assert-True ([IO.File]::ReadAllText((Join-Path $zebar $f)) -match 'closeByHover\(') "$f does not use it"
    }
}

Complete-Cases
