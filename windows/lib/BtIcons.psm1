# The stroke icons the Bluetooth panel draws (24 x 24, 2 px round stroke), in
# the design's style. PanelKit keeps its icons in its own script scope and
# is not edited for this, so they are put there through the module.

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'PanelKit.psm1')

$script:BtIcons = @{
    bluetooth  = '<path d="M7 7l10 10-5 5V2l5 5L7 17"/>'
    headphones = '<path d="M4 15v-3a8 8 0 0 1 16 0v3"/><rect x="3" y="14" width="4.5" height="7" rx="1.8"/><rect x="16.5" y="14" width="4.5" height="7" rx="1.8"/>'
    keyboard   = '<rect x="2" y="6" width="20" height="12" rx="2.5"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7.5 14h9"/>'
    gamepad    = '<rect x="2" y="7" width="20" height="10" rx="5"/><path d="M7 12h4M9 10v4M15.5 11.5h.01M18 13h.01"/>'
    speaker    = '<path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11"/>'
    trash      = '<path d="M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13M10 11v6M14 11v6"/>'
    plug       = '<path d="M9 3v5M15 3v5M6 8h12v3a6 6 0 0 1-12 0zM12 17v4"/>'
    sliders    = '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>'
    mouse      = '<rect x="7" y="3" width="10" height="18" rx="5"/><path d="M12 7v4"/>'
    phone      = '<rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/>'
    car        = '<path d="M5 17v-5l2-5h10l2 5v5zM3 12h18"/><path d="M7.5 14.5h.01M16.5 14.5h.01"/>'
    computer   = '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8M12 17v4"/>'
    watch      = '<rect x="7" y="6" width="10" height="12" rx="3"/><path d="M9 6l1-3h4l1 3M9 18l1 3h4l1-3"/>'
    battery    = '<rect x="2" y="8" width="17" height="8" rx="2.5"/><path d="M21.5 11v2"/>'
}

function Register-BtIcons {
    $panelKit = Get-Module PanelKit
    if (-not $panelKit) { throw 'PanelKit is not loaded' }
    & $panelKit { param($icons) foreach ($k in $icons.Keys) { $script:PanelIcons[$k] = $icons[$k] } } $script:BtIcons
}

Export-ModuleMember -Function Register-BtIcons
