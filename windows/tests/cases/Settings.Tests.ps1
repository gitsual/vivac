# Settings: choices with one writer each, validated before they land.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
Import-Module (Join-Path (Get-RepoRoot) 'lib\Vivac.psm1') -Force
$root = Get-RepoRoot

$dir = New-TempProfile
try {
    Case 'a missing settings file means the defaults' {
        $s = Read-VivacSettings
        Assert-Equal 'bad-romance' $s['theme']
        Assert-Equal 'lwin' $s['mod']
    }
    Case 'a setting is written in place, other lines kept' {
        Set-VivacSetting theme cosmos
        Set-VivacSetting mod lwin
        Set-VivacSetting theme gatsby
        $text = [IO.File]::ReadAllText((Get-VivacPaths).Settings)
        Assert-Equal "theme=gatsby`nmod=lwin`n" $text
    }
    Case 'invalid values are refused before they land' {
        Assert-Throws { Set-VivacSetting theme nonexistent } 'no theme'
        Assert-Throws { Set-VivacSetting mod ctrl } 'not a valid value'
        Assert-Throws { Set-VivacSetting weather_location 'Madrid' } 'not a valid value'
        Assert-Throws { Set-VivacSetting colour red } 'unknown setting'
        Set-VivacSetting weather_location '40.42,-3.70'
        Assert-Equal '40.42,-3.70' (Read-VivacSettings)['weather_location']
    }
} finally { Remove-TempProfile $dir }

# The single-writer rule: only lib/Vivac.psm1 writes the settings file. Every
# other script goes through Set-VivacSetting, which validates.
Case 'nothing but lib/Vivac.psm1 writes the settings file directly' {
    foreach ($f in Get-RepoFiles @('*.ps1', '*.psm1') | Where-Object { $_.Name -notin 'Vivac.psm1' -and $_.FullName -notmatch '\\tests\\' }) {
        $text = [IO.File]::ReadAllText($f.FullName)
        Assert-True ($text -notmatch '\.Settings\b[^\r\n]*(Set-Content|Out-File|WriteAll|Write-VivacFile|Set-VivacKeyValue)') "$($f.Name) writes the settings file"
        Assert-True ($text -notmatch 'Set-VivacKeyValue') "$($f.Name) bypasses Set-VivacSetting"
    }
}
Complete-Cases
