# Hardware detection against machines this one is not, and what the bar
# becomes on each: the classification and the per-machine render are pure
# functions of a snapshot, so both are pinned by golden files.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Deploy.psm1') -Force

$root = Get-RepoRoot
$detector = Join-Path $root 'scripts\hardware-facts.ps1'
$expectedModules = @{
    'desktop-nvidia'    = 'wireless wired bluetooth cpu memory disk gpu usb audio security theme power updates'
    'laptop-intel'      = 'wireless wired bluetooth cpu memory disk battery usb audio security theme power updates'
    'laptop-amd-hybrid' = 'wireless wired bluetooth cpu memory disk gpu battery usb audio security theme power updates'
    'vm-hyperv'         = 'wired cpu memory disk usb audio security theme power updates'
    'vm-vmware'         = 'wired cpu memory disk usb audio security theme power updates'
}

foreach ($dir in Get-ChildItem -LiteralPath (Join-Path $root 'tests\fixtures') -Directory) {
    $name = $dir.Name
    Case "${name} classifies to its golden facts" {
        $got = (& $detector -Snapshot (Join-Path $dir.FullName 'snapshot.json')) -join "`n"
        $want = ([IO.File]::ReadAllText((Join-Path $root "tests\golden\$name\hardware-facts"))).TrimEnd("`n")
        Assert-Equal $want $got
    }
    Case "${name}: the bar shows exactly the gauges the machine can answer for" {
        $facts = Read-VivacFacts @((Join-Path $root "tests\golden\$name\hardware-facts"))
        $settings = [ordered]@{ language = 'en'; theme = 'bad-romance'; mod = 'alt'; weather_location = 'auto' }
        $ctx = Get-MachineContext (Read-VivacTheme 'bad-romance') $settings $facts
        $js = (Get-MachineRender $ctx 'zebar' | Where-Object { $_.Relative -eq 'vivac\config.js' }).Text
        $modules = @([regex]::Matches(($js -split 'modules: \[')[1], "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value }) -join ' '
        Assert-Equal $expectedModules[$name] $modules
    }
}
Case 'no fact outside the allowlist can be emitted' {
    $text = (& $detector -Snapshot (Join-Path $root 'tests\fixtures\laptop-intel\snapshot.json')) -join "`n"
    Assert-True ($text -notmatch 'Generic|Example|VEN_') 'model, maker or device ids leaked into the facts'
}
Case 'the override file wins key by key' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vivac-ovr-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.File]::WriteAllText($tmp, "has_wifi=no`n")
    try {
        $f = Read-VivacFacts @((Join-Path $root 'tests\golden\laptop-intel\hardware-facts'), $tmp)
        Assert-Equal 'no' $f['has_wifi']
        Assert-Equal 'laptop' $f['chassis']
    } finally { Remove-Item -LiteralPath $tmp -Force }
}
Case 'weather: auto, off and coordinates render as the bar expects' {
    $facts = Read-VivacFacts @((Join-Path $root 'tests\golden\vm-vmware\hardware-facts'))
    foreach ($pair in @(@('auto', '{}'), @('off', 'null'), @('40.42,-3.70', '{ latitude: 40.42, longitude: -3.70 }'))) {
        $settings = [ordered]@{ language = 'en'; theme = 'bad-romance'; mod = 'alt'; weather_location = $pair[0] }
        Assert-Equal $pair[1] (Get-MachineContext (Read-VivacTheme 'bad-romance') $settings $facts).Tokens['WEATHER_JSON']
    }
}
Complete-Cases
