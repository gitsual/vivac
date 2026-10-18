# The help registry and the GlazeWM template describe the same keys: every
# annotated binding has a row, every glazewm row has a binding, every label
# exists, and no key combination is bound twice.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Deploy.psm1') -Force

$root = Get-RepoRoot
$template = [IO.File]::ReadAllLines((Join-Path $root 'render\glazewm\config.yaml.in'))
$registry = Read-VivacHelpRegistry
$en = (Read-VivacKeyValue (Join-Path $root 'i18n\en.conf')).Values

# Annotated bindings: a '# @help: <pane> <label>' line, then the entry whose
# bindings line follows. Guards are stripped first: an annotation inside a
# guarded block is still an annotation.
$annotated = @()
for ($i = 0; $i -lt $template.Count; $i++) {
    $line = $template[$i] -replace '^@\?[^@]*@', ''
    if ($line -match '#\s*@help:\s*(\S+)\s+(\S+)') {
        $pane = $Matches[1]; $label = $Matches[2]
        for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $template.Count); $j++) {
            $b = $template[$j] -replace '^@\?[^@]*@', ''
            if ($b -match "bindings:\s*\['([^']+)'\]") {
                $annotated += [pscustomobject]@{ Bind = ($Matches[1] -replace '^@SET_MOD@', 'MOD'); Pane = $pane; Label = $label }
                break
            }
        }
    }
}

Case 'every keybinding in the template carries a @help annotation' {
    $all = @($template | Where-Object { $_ -match "^\S*\s+bindings:\s*\[" }).Count
    Assert-Equal $all $annotated.Count 'bindings vs annotations'
}
Case 'every annotated binding has a registry row with the same label' {
    foreach ($a in $annotated) {
        $row = $registry | Where-Object { $_.Bind -eq $a.Bind }
        Assert-True $row "no registry row for $($a.Bind)"
        Assert-Equal $a.Label $row.Label "label of $($a.Bind)"
    }
}
Case 'every glazewm row in the registry has a binding in the template' {
    foreach ($r in $registry | Where-Object { $_.Type -eq 'glazewm' }) {
        Assert-True ($annotated | Where-Object { $_.Bind -eq $r.Bind }) "registry row $($r.Bind) has no binding"
    }
}
Case 'every registry label exists in the English table' {
    $missing = @($registry | Where-Object { -not $en.Contains($_.Label) } | ForEach-Object { $_.Label })
    Assert-True (-not $missing.Count) "missing labels: $($missing -join ', ')"
}
Case 'registry panes and action types are the known ones' {
    foreach ($r in $registry) {
        Assert-True (@('wm', 'browser', 'shell', 'editor', 'system') -contains $r.Pane) "pane $($r.Pane)"
        Assert-True (@('glazewm', 'vivac', 'doc') -contains $r.Type) "type $($r.Type)"
    }
}
foreach ($mod in 'alt', 'lwin') {
    Case "rendered with $mod, no key combination is bound twice" {
        $facts = Read-VivacFacts @((Join-Path $root 'tests\golden\desktop-nvidia\hardware-facts'))
        $settings = [ordered]@{ language = 'en'; theme = 'bad-romance'; mod = $mod; weather_location = 'auto' }
        $ctx = Get-MachineContext (Read-VivacTheme 'bad-romance') $settings $facts
        $yaml = (Get-MachineRender $ctx 'glazewm')[0].Text
        $binds = @([regex]::Matches($yaml, "bindings:\s*\[([^\]]+)\]") | ForEach-Object { $_.Groups[1].Value -split ',' } | ForEach-Object { $_.Trim().Trim("'") })
        $dupes = @($binds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        Assert-True (-not $dupes.Count) "bound twice: $($dupes -join ', ')"
        Assert-True ($yaml -notmatch '@[A-Z_]+@') 'a token survived the render'
        if ($mod -eq 'lwin') { Assert-True ($binds -notcontains 'lwin+v') 'Win+V is Windows own; the forwarder must not be bound' }
        else { Assert-True ($binds -contains 'alt+v') 'with Alt, the clipboard forwarder is bound' }
    }
}
Case 'the launcher gets the theme; its own hotkey is left alone unless vivac set it' {
    $merged = Get-FlowMerge '{"Theme":"Win11Light","Hotkey":"Ctrl + Space","Other":1}' | ConvertFrom-Json
    Assert-Equal 'vivac' $merged.Theme
    Assert-Equal 'Ctrl + Space' $merged.Hotkey 'the user hotkey is kept'
    Assert-Equal 1 $merged.Other 'unrelated launcher settings are kept'
    $old = Get-FlowMerge '{"Theme":"vivac","Hotkey":"Alt + R"}' | ConvertFrom-Json
    Assert-Equal 'Alt + Space' $old.Hotkey 'the MOD+R an earlier vivac set no longer fights GlazeWM'
    $same = '{ "Theme": "vivac", "Hotkey": "Alt + Space" }'
    Assert-True ((Get-FlowMerge $same) -ceq $same) 'a file already right comes back untouched'
}
Complete-Cases
