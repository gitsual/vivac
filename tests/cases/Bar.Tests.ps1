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
Complete-Cases
