# The renderer and the predicate grammar: the two things every themed or
# per-machine file passes through.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force

$tokens = [ordered]@{ COLOR_BG = '2D1F2D'; NAME_WORD = 'vivac' }

Case 'a token renders as stored' {
    Assert-Equal '#2D1F2D;' (Expand-VivacString '#@COLOR_BG@;' $tokens)
}
Case 'filters: lower, rgb, dark, darker, dim, bgr' {
    Assert-Equal '2d1f2d' (Expand-VivacString '@COLOR_BG:lower@' $tokens)
    Assert-Equal '45, 31, 45' (Expand-VivacString '@COLOR_BG:rgb@' $tokens)
    Assert-Equal '1F151F' (Expand-VivacString '@COLOR_BG:dark@' $tokens)
    Assert-Equal '140D14' (Expand-VivacString '@COLOR_BG:darker@' $tokens)
    Assert-Equal '23181C' (ConvertTo-VivacScaled '2D1F24' 78)
    Assert-Equal '2D1F2D' (Expand-VivacString '@COLOR_BG:bgr@' $tokens)
}
Case 'an unknown token is an error, never an empty string' {
    Assert-Throws { Expand-VivacString '@NOPE@' $tokens } 'unknown token'
}
Case 'an unknown filter is an error' {
    Assert-Throws { Expand-VivacString '@COLOR_BG:sepia@' $tokens } 'unknown filter'
}
Case 'a colour filter on a word is an error' {
    Assert-Throws { Expand-VivacString '@NAME_WORD:rgb@' $tokens } 'needs a colour'
}
Case 'text around a token is literal, CSS and JSON syntax included' {
    Assert-Equal 'a { color: rgba(45, 31, 45, 0.5); } ${x} $(y)' (Expand-VivacString 'a { color: rgba(@COLOR_BG:rgb@, 0.5); } ${x} $(y)' $tokens)
}
Case 'a guard keeps or drops its line' {
    $facts = [ordered]@{ has_wifi = 'yes'; gpu_vendors = 'intel nvidia' }
    $text = "a`n@?has_wifi=yes@b`n@?has_wifi=no@c`n@?gpu_vendors~nvidia@d"
    Assert-Equal "a`nb`nd" (Expand-VivacTemplate $text $tokens $facts)
}
Case 'a guard without facts is an error' {
    Assert-Throws { Expand-VivacTemplate '@?has_wifi=yes@x' $tokens $null } 'without hardware facts'
}
Case 'predicates: = != ~ && ||, with && binding tighter' {
    $f = [ordered]@{ chassis = 'laptop'; gpu_vendors = 'amd nvidia'; has_battery = 'yes' }
    Assert-True (Test-VivacPredicate 'chassis=laptop' $f)
    Assert-True (Test-VivacPredicate 'chassis!=desktop' $f)
    Assert-True (Test-VivacPredicate 'gpu_vendors~nvidia' $f)
    Assert-True (-not (Test-VivacPredicate 'gpu_vendors~nvid' $f)) 'a ~ match is a whole word'
    Assert-True (Test-VivacPredicate 'chassis=desktop || has_battery=yes && gpu_vendors~amd' $f)
    Assert-True (-not (Test-VivacPredicate 'chassis=desktop && has_battery=yes || chassis=vm' $f))
    Assert-True (Test-VivacPredicate '' $f) 'an empty predicate holds'
}
Case 'a predicate naming an unknown fact is an error, not false' {
    Assert-Throws { Test-VivacPredicate 'has_moon=yes' ([ordered]@{ chassis = 'vm' }) } 'unknown fact'
}
Case 'a malformed predicate term is an error' {
    Assert-Throws { Test-VivacPredicate 'chassis==vm' ([ordered]@{ chassis = 'vm' }) } 'bad predicate'
}
Case 'bindings print as the keys are labelled' {
    Assert-Equal 'Alt+Shift+.' (Format-VivacBind 'MOD+shift+oem_period' 'alt')
    Assert-Equal 'Win+Ctrl+Left' (Format-VivacBind 'MOD+control+left' 'lwin')
    Assert-Equal 'Alt+F1' (Format-VivacBind 'MOD+f1' 'alt')
    Assert-Equal 'Ctrl+Shift+T' (Format-VivacBind 'Ctrl+Shift+T' 'alt')
}
Complete-Cases
