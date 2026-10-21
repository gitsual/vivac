# The checkout itself: every script parses and is ASCII, every JSON and XML
# file is well-formed, the committed renders match their templates, the
# manifests are sane, and nothing private is in any tracked file.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Deploy.psm1') -Force
$root = Get-RepoRoot

Case 'every PowerShell file parses' {
    foreach ($f in Get-RepoFiles @('*.ps1', '*.psm1')) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        Assert-True (-not $errors) "$($f.Name): $(@($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')"
    }
}
# Windows PowerShell 5.1 reads a BOM-less script as ANSI, so a single accented
# letter in a .ps1 turns into mojibake at run time. Text for people lives in
# i18n/, which is read as UTF-8 on purpose.
Case 'every PowerShell file is plain ASCII' {
    foreach ($f in Get-RepoFiles @('*.ps1', '*.psm1')) {
        $bad = @([IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 127 }).Count
        Assert-Equal 0 $bad "non-ASCII bytes in $($f.Name)"
    }
}
Case 'every JSON file is well-formed' {
    foreach ($f in Get-RepoFiles @('*.json')) {
        try { [void](Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json) } catch { throw "$($f.FullName): $($_.Exception.Message)" }
    }
}
Case 'the bar pack has every field the Zebar schema requires' {
    $pack = Get-Content -Raw -LiteralPath (Join-Path $root 'static\zebar\vivac\zpack.json') | ConvertFrom-Json
    foreach ($k in 'name', 'version', 'widgets') { Assert-True $pack.PSObject.Properties[$k] "pack.$k" }
    foreach ($w in $pack.widgets) {
        foreach ($k in 'name', 'htmlPath', 'zOrder', 'shownInTaskbar', 'focused', 'resizable', 'transparent', 'presets') { Assert-True $w.PSObject.Properties[$k] "widget.$k" }
        foreach ($p in $w.presets) { foreach ($k in 'name', 'anchor', 'offsetX', 'offsetY', 'width', 'height', 'monitorSelection') { Assert-True $p.PSObject.Properties[$k] "preset.$k" } }
        Assert-True (Test-Path (Join-Path $root "static\zebar\vivac\$($w.htmlPath)")) 'htmlPath exists'
    }
    $settings = Get-ZebarSettingsMerge '' | ConvertFrom-Json
    Assert-Equal "$($pack.name)/bar/default" ("{0}/{1}/{2}" -f $settings.startupConfigs[0].pack, $settings.startupConfigs[0].widget, $settings.startupConfigs[0].preset)
}
# A bar module that fails to load leaves the bar blank: its stylesheet draws,
# nothing else does. Zebar loads them as ES modules, which reject what a
# script tolerates (a name declared twice), so they are checked as .mjs.
Case 'every bar module parses as an ES module' {
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) { Write-Host '  (node not installed: skipped)'; return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vivac-mjs-' + [guid]::NewGuid())
    [void](New-Item -ItemType Directory -Path $tmp)
    try {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root 'static\zebar\vivac') -Filter '*.js') {
            $copy = Join-Path $tmp ($f.BaseName + '.mjs')
            Copy-Item -LiteralPath $f.FullName -Destination $copy
            $out = & $node.Source --check $copy 2>&1
            Assert-Equal 0 $LASTEXITCODE "$($f.Name): $($out -join ' ')"
        }
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
# The bar draws at sign-in, before the network may be up: nothing it needs
# to start is fetched from the internet (static/zebar/vivac/zebar-client.js).
Case 'the bar imports nothing from the network' {
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root 'static\zebar\vivac') -Include '*.js', '*.html' -Recurse) {
        $hits = @(Select-String -LiteralPath $f.FullName -Pattern "(from\s+|import\s*\(\s*|src=)['""]https?:" | ForEach-Object { $_.LineNumber })
        Assert-Equal 0 $hits.Count "$($f.Name) imports from the network at line $($hits -join ', ')"
    }
}
Case 'the bar start-up list is merged: Zebar own rewrite of it is not a change' {
    $zebarRewrite = "{`n  `"`$schema`": `"https://example/v9.9.9/settings-schema.json`",`n  `"startupConfigs`": [`n    {`n      `"pack`": `"vivac`",`n      `"widget`": `"bar`",`n      `"preset`": `"default`"`n    }`n  ]`n}`n"
    Assert-True ((Get-ZebarSettingsMerge $zebarRewrite) -ceq $zebarRewrite) 'returned unchanged'
    $starter = '{"startupConfigs":[{"pack":"glzr-io.starter","widget":"vanilla","preset":"default"}]}'
    Assert-Equal 'vivac' ((Get-ZebarSettingsMerge $starter | ConvertFrom-Json).startupConfigs[0].pack)
}
Case 'the bar may only run the verbs it is granted' {
    $pack = Get-Content -Raw -LiteralPath (Join-Path $root 'static\zebar\vivac\zpack.json') | ConvertFrom-Json
    $grant = ($pack.widgets[0].privileges.shellCommands | Where-Object { $_.program -eq 'cmd.exe' -and $_.argsRegex -match 'pipe' }).argsRegex
    Assert-True ($grant -notmatch '\\[1-9]') 'Zebar matches with Rust regex, which has no backreferences'
    # The exact argument line bar.js builds, for each verb.
    $line = '/c echo VERB>\\.\pipe\vivac-someone 2>nul || conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\x\vivac\bin\vivac.ps1 VERB'
    foreach ($verb in 'theme', 'power', 'help', 'sound') {
        Assert-True ($line.Replace('VERB', $verb) -match $grant) "$verb is granted"
    }
    Assert-True ($line.Replace('VERB', 'audit') -notmatch $grant) 'no other verb is'
    Assert-True (($line.Replace('VERB', 'help') + ' & calc') -notmatch $grant) 'nothing can be appended'
    $js = [IO.File]::ReadAllText((Join-Path $root 'static\zebar\vivac\bar.js'))
    Assert-True ($js -match [regex]::Escape('`/c echo ${verb}>\\\\.\\pipe\\${config.pipe} 2>nul || conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File ${config.repo}\\bin\\vivac.ps1 ${verb}`')) 'bar.js builds the line the grant expects'
    # The proof of life bin/vivac-bar-watch.ps1 reads: one fixed line, nothing appended.
    $alive = ($pack.widgets[0].privileges.shellCommands | Where-Object { $_.program -eq 'cmd.exe' -and $_.argsRegex -match 'bar\.alive' }).argsRegex
    $aliveLine = '/d /c cd /d %LOCALAPPDATA%\vivac && type nul>bar.alive'
    Assert-True ($aliveLine -match $alive) 'the bar may stamp bar.alive'
    Assert-True (($aliveLine + ' & calc') -notmatch $alive) 'nothing can be appended to the stamp'
    Assert-True ($js.Contains("'" + $aliveLine.Replace('\', '\\') + "'")) 'bar.js stamps the line the grant expects'
}
Case 'every XML and SVG file and every rendered XAML is well-formed' {
    foreach ($f in Get-RepoFiles @('*.xml', '*.svg', '*.xaml')) { [void][xml][IO.File]::ReadAllText($f.FullName) }
    foreach ($name in Get-VivacCatalogue) {
        $x = (Get-ThemedRender (Read-VivacTheme $name) 'flow')[0].Text
        [void][xml]$x
    }
}
# Flow Launcher refuses a whole theme over one base style it does not have,
# and silently falls back to its own; the styles a release ships are in the
# themes it ships. Checked against the installed release when there is one.
Case 'the launcher theme only builds on base styles the installed Flow Launcher has' {
    $installed = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'FlowLauncher') -Directory -Filter 'app-*' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $installed) { return }
    $known = @{}
    foreach ($f in Get-ChildItem (Join-Path $installed.FullName 'Themes') -Filter '*.xaml') {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($f.FullName), 'StaticResource (Base\w+)')) { $known[$m.Groups[1].Value] = $true }
    }
    $ours = [regex]::Matches([IO.File]::ReadAllText((Join-Path $root 'templates\flow\vivac.xaml.in')), 'StaticResource (Base\w+)') | ForEach-Object { $_.Groups[1].Value }
    $missing = @($ours | Where-Object { -not $known.ContainsKey($_) } | Sort-Object -Unique)
    Assert-True (-not $missing.Count) "not in Flow Launcher $($installed.Name): $($missing -join ', ')"
}
# Inside the product (windows\ next to shared\), the palettes both systems use
# are copies of shared\data\; a copy edited here instead of there fails.
Case 'the shared data matches shared\ (inside the product)' {
    $sync = Join-Path (Split-Path -Parent $root) 'shared\sync.ps1'
    if (-not (Test-Path -LiteralPath $sync)) { Write-Host '  (not inside the product: skipped)'; return }
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sync -Check 2>&1
    Assert-Equal 0 $LASTEXITCODE ($out -join '; ')
}
Case 'the committed renders under dotfiles/ match their templates (no drift)' {
    $theme = Read-VivacTheme (Get-VivacDefaultTheme)
    $expected = @{}
    foreach ($pkg in Get-ChildItem -LiteralPath (Join-Path $root 'templates') -Directory | Where-Object { $_.Name -notin 'wallpaper', 'brand' }) {
        foreach ($f in Get-ThemedRender $theme $pkg.Name) { $expected["$($pkg.Name)\$($f.Relative)"] = $f.Text }
    }
    $committed = @{}
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root 'dotfiles') -Recurse -File) {
        $committed[$f.FullName.Substring((Join-Path $root 'dotfiles').Length + 1)] = [IO.File]::ReadAllText($f.FullName)
    }
    foreach ($k in $expected.Keys) {
        Assert-True $committed.ContainsKey($k) "dotfiles\$k is missing; run scripts\render.ps1"
        Assert-True ($committed[$k] -ceq $expected[$k]) "dotfiles\$k drifted from its template; run scripts\render.ps1"
    }
    foreach ($k in $committed.Keys) { Assert-True $expected.ContainsKey($k) "dotfiles\$k has no template" }
}
Case 'docs/keys.md is the registry, rendered (no drift)' {
    Assert-True ([IO.File]::ReadAllText((Join-Path $root 'docs\keys.md')) -ceq (Get-VivacKeysMarkdown)) 'docs\keys.md drifted; run scripts\render.ps1'
}
Case 'package manifests: valid winget ids, no duplicates, every selector points at one' {
    $seen = @{}
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root 'packages') -Filter '*.txt') {
        foreach ($line in [IO.File]::ReadAllLines($f.FullName) | Where-Object { $_ -notmatch '^\s*(#|$)' }) {
            Assert-True ($line -match '^[A-Za-z0-9][A-Za-z0-9.+-]*\.[A-Za-z0-9.+-]+$') "not a winget id: $line"
            Assert-True (-not $seen.ContainsKey($line)) "$line is listed twice"
            $seen[$line] = $true
        }
    }
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $root 'data\selectors.tsv')) | Where-Object { $_ -notmatch '^\s*(#|$)' }) {
        Assert-True (Test-Path (Join-Path $root (($line -split "`t")[1]))) "selector manifest of: $line"
    }
}
# Nothing that identifies a person or a machine belongs in the repository.
Case 'privacy: no user paths, e-mail addresses, SIDs, MAC addresses or serials' {
    $patterns = @(
        @{ Name = 'user profile path'; Re = '(?i)[A-Z]:\\Users\\(?!Public\\|<|%|\$)[A-Za-z0-9._-]+\\' },
        @{ Name = 'e-mail address'; Re = '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}' },
        @{ Name = 'Windows SID'; Re = 'S-1-5-21-\d+-\d+-\d+' },
        @{ Name = 'MAC address'; Re = '(?i)\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b' }
    )
    $allow = 'noreply@anthropic\.com|git@github\.com'
    foreach ($f in Get-RepoFiles) {
        if ($f.Extension -in '.png', '.jpg', '.mp4', '.gif') { continue }
        $text = [IO.File]::ReadAllText($f.FullName)
        foreach ($p in $patterns) {
            foreach ($m in [regex]::Matches($text, $p.Re)) {
                if ($m.Value -match $allow) { continue }
                throw "$($p.Name) in $($f.FullName.Substring($root.Length + 1)): $($m.Value)"
            }
        }
    }
}
Complete-Cases
