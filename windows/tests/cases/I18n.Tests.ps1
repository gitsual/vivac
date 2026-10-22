# Every language carries exactly the English keys with the same placeholders,
# and every key the code asks for exists.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force

$root = Get-RepoRoot
$en = (Read-VivacKeyValue (Join-Path $root 'i18n\en.conf')).Values

foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'i18n') -Filter '*.conf' | Where-Object { $_.Name -ne 'en.conf' }) {
    $lang = (Read-VivacKeyValue $file.FullName).Values
    Case "$($file.BaseName) has exactly the English keys" {
        $missing = @($en.Keys | Where-Object { -not $lang.Contains($_) })
        $extra = @($lang.Keys | Where-Object { -not $en.Contains($_) })
        Assert-True (-not $missing.Count) "missing: $($missing -join ', ')"
        Assert-True (-not $extra.Count) "not in English: $($extra -join ', ')"
    }
    Case "$($file.BaseName) keeps every placeholder of each string" {
        foreach ($k in $en.Keys) {
            if (-not $lang.Contains($k)) { continue }
            $a = @([regex]::Matches($en[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            $b = @([regex]::Matches($lang[$k], '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ','
            Assert-Equal $a $b "placeholders of $k"
        }
    }
}

Case 'every key the code asks for exists in English' {
    $used = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in Get-RepoFiles @('*.ps1', '*.psm1') | Where-Object { $_.FullName -notmatch '\\tests\\' }) {
        $text = [IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($text, "(?:\bT|Say|Title|Section|Get-VivacString)\s+'([a-z_]+\.[a-z_.0-9]+)'")) { [void]$used.Add($m.Groups[1].Value) }
    }
    # Keys built at run time, from lists the code also holds.
    foreach ($p in 'wm', 'browser', 'shell', 'editor', 'system') { [void]$used.Add("help.pane.$p") }
    foreach ($p in 'lock', 'logout', 'sleep', 'restart', 'shutdown') { [void]$used.Add("power.$p") }
    foreach ($p in 'desktop', 'wired', 'no_link', 'not_connected', 'no_address', 'theme', 'power', 'bt_on', 'bt_off', 'eject', 'updates', 'updates_none', 'reboot', 'av_on', 'av_off') { [void]$used.Add("bar.$p") }
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $root 'data\selectors.tsv'))) {
        if ($line -notmatch '^\s*(#|$)') { [void]$used.Add(($line -split "`t")[4]) }
    }
    $missing = @($used | Where-Object { -not $en.Contains($_) })
    Assert-True (-not $missing.Count) "asked for but missing: $($missing -join ', ')"
}
Case 'a missing translation falls back to English, marked' {
    $t = Import-VivacStrings 'es'
    Assert-True ($t['help.wm.terminal'] -notmatch '^\[en\]') 'Spanish carries its own'
    Assert-Equal '[no.such.key]' (Get-VivacString 'no.such.key')
}
Complete-Cases
