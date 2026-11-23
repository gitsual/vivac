# The bar's guard (lib/Bar.psm1): a pack that would load blank is caught
# before scripts/deploy.ps1 writes it. Each case builds a small pack in a
# scratch folder, breaks one thing, and expects exactly that to be named.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Bar.psm1') -Force

$hasNode = [bool](Get-Command node -CommandType Application -ErrorAction SilentlyContinue)

function New-Pack {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('vivac-pack-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $dir)
    $files = @{
        'zpack.json' = '{ "name": "t", "widgets": [ { "name": "bar", "htmlPath": "./index.html" } ] }'
        'index.html' = '<link rel="stylesheet" href="./styles.css" /><script type="module" src="./bar.js"></script>'
        'styles.css' = '.bar { position: absolute; }'
        'bar.js'     = "import * as z from './client.js';`nimport { config, other as o } from './config.js';`nconst icons = await fetch('./icons.json');`nconst wx = await fetch('https://api.example.org/forecast');`nfunction beat() {}`n"
        'client.js'  = "const a = 1;`nexport { a as shellExec };`n"
        'config.js'  = "export const config = {};`nexport function other() {}`n"
        'icons.json' = '{}'
    }
    foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $dir $k), $files[$k]) }
    $dir
}
function Edit-Pack([string]$Dir, [string]$File, [string]$From, [string]$To) {
    $p = Join-Path $Dir $File
    [IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p).Replace($From, $To))
}
function Assert-Only([string]$Dir, [string]$Pattern) {
    try {
        $found = @(Test-VivacBarFiles $Dir)
        Assert-Equal 1 $found.Count ("one problem, got: " + ($found -join ' | '))
        Assert-True ($found[0] -match $Pattern) "expected /$Pattern/, got: $($found[0])"
    } finally { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Case 'a sound pack has no problems (data fetched from the network is fine)' {
    $d = New-Pack
    try { Assert-Equal 0 @(Test-VivacBarFiles $d).Count (@(Test-VivacBarFiles $d) -join ' | ') }
    finally { Remove-Item -LiteralPath $d -Recurse -Force }
}
Case 'a module imported from the network is refused' {
    $d = New-Pack; Edit-Pack $d 'bar.js' "'./client.js'" "'https://esm.sh/zebar@3.0'"
    Assert-Only $d 'bar\.js loads https://esm\.sh'
}
Case 'a missing file a page loads is refused' {
    $d = New-Pack; Remove-Item (Join-Path $d 'icons.json')
    Assert-Only $d 'icons\.json, which is missing'
}
Case 'a missing widget page is refused' {
    $d = New-Pack; Edit-Pack $d 'zpack.json' './index.html' './gone.html'
    Assert-Only $d 'widget bar: \./gone\.html is missing'
}
Case 'a name imported that the sibling does not export is refused' {
    $d = New-Pack; Edit-Pack $d 'bar.js' '{ config, other as o }' '{ config, nope }'
    Assert-Only $d 'imports nope from \./config\.js'
}
Case 'a name declared twice (fine in a script, fatal in a module) is refused' {
    if (-not $hasNode) { Write-Host '  (node not installed: skipped)'; return }
    $d = New-Pack; Edit-Pack $d 'bar.js' 'function beat() {}' "function beat() {}`nlet beat = 1;"
    Assert-Only $d 'bar\.js does not parse as a module'
}
Case 'an unreadable zpack.json is refused' {
    $d = New-Pack; [IO.File]::WriteAllText((Join-Path $d 'zpack.json'), '{ nope')
    Assert-Only $d '^zpack\.json:'
}

# A sentence on the bar shoves every pill beside it (2026-10-27: the
# Malwarebytes trial countdown). The shield shows a glyph only, and no pill,
# whatever a module hands it, may grow past its cap.
Case 'the shield pill carries no words and pills cannot grow without bound' {
    $root = Get-RepoRoot
    $js = [IO.File]::ReadAllText((Join-Path $root 'static\zebar\vivac\bar.js'))
    $shield = [regex]::Match($js, '(?s)function securityPill\(\) \{.*?\n\}').Value
    Assert-True ($shield.Length -gt 0) 'securityPill not found in bar.js'
    Assert-True ($shield -notmatch 'security\.text') 'the shield pill prints security.text on the bar'
    foreach ($css in 'templates\zebar\vivac\styles.css.in', 'dotfiles\zebar\vivac\styles.css') {
        $rule = [regex]::Match([IO.File]::ReadAllText((Join-Path $root $css)), '(?s)\n\.pill \{.*?\}').Value
        Assert-True ($rule -match 'max-width:' -and $rule -match 'overflow: hidden') "$css .pill has no width cap"
    }
}

# The shipped pack, as it is in the repository: what every popup page loads is
# there, the module graph links, and the panels' grants cover exactly the
# commands the pages run.
Case 'the shipped pack passes the guard (config.js is rendered per machine, so a stub stands in)' {
    $root = Get-RepoRoot
    $d = Join-Path ([IO.Path]::GetTempPath()) ('vivac-real-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        Copy-Item -LiteralPath (Join-Path $root 'static\zebar\vivac') -Destination $d -Recurse
        [IO.File]::WriteAllText((Join-Path $d 'config.js'), "export const config = {};`n")
        [IO.File]::WriteAllText((Join-Path $d 'styles.css'), '.bar { position: absolute; }')
        Assert-Equal 0 @(Test-VivacBarFiles $d).Count (@(Test-VivacBarFiles $d) -join ' | ')
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Case 'the system panel is granted every sysinfo mode it runs, and the bar its nvidia-smi query' {
    $root = Get-RepoRoot
    $pack = [IO.File]::ReadAllText((Join-Path $root 'static\zebar\vivac\zpack.json')) | ConvertFrom-Json
    $sys = @($pack.widgets) | Where-Object { $_.name -eq 'system' }
    Assert-True ($null -ne $sys) 'no system widget in zpack.json'
    $re = $sys.privileges.shellCommands[0].argsRegex
    $js = [IO.File]::ReadAllText((Join-Path $root 'static\zebar\vivac\system.js'))
    $modes = @([regex]::Matches($js, "sysinfo\('(-\w+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Assert-True ($modes.Count -ge 5) "expected the panel to ask for at least five modes, found $($modes -join ' ')"
    foreach ($m in $modes) {
        $line = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\vivac\bin\vivac-sysinfo.ps1 $m"
        Assert-True ($line -match $re) "zpack.json does not grant sysinfo $m"
    }
    $bar = @($pack.widgets) | Where-Object { $_.name -eq 'bar' }
    $nv = @($bar.privileges.shellCommands | Where-Object { $_.program -eq 'nvidia-smi' })[0].argsRegex
    Assert-True ('--query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits' -match $nv) 'the bar may not run its nvidia-smi query'
    $sysinfo = [IO.File]::ReadAllText((Join-Path $root 'bin\vivac-sysinfo.ps1'))
    foreach ($m in $modes) { Assert-True ($sysinfo -match ('\$' + (Get-Culture).TextInfo.ToTitleCase($m.TrimStart('-')) + '\b')) "vivac-sysinfo.ps1 has no $m switch" }
}
Case 'every label the panels read is one the deploy hands over' {
    $root = Get-RepoRoot
    $deploy = [IO.File]::ReadAllText((Join-Path $root 'lib\Deploy.psm1'))
    $given = @([regex]::Matches(([regex]::Match($deploy, "(?s)\$labels = \[ordered\]@\{\}.*?\) \{").Value), "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
    foreach ($f in 'bar.js', 'calendar.js', 'forecast.js', 'system.js') {
        $text = [IO.File]::ReadAllText((Join-Path $root "static\zebar\vivac\$f"))
        foreach ($m in [regex]::Matches($text, '\b(?:L|config\.labels)\.(\w+)')) {
            Assert-True ($given -contains $m.Groups[1].Value) "$f reads label $($m.Groups[1].Value), which Deploy.psm1 does not hand over"
        }
    }
}

Complete-Cases
