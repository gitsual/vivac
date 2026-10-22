<#
.SYNOPSIS
  Re-render the committed default theme under dotfiles/.

.DESCRIPTION
  templates/ holds every themed file as a template; dotfiles/ holds its render
  in the default palette, committed so a reader sees real files and so a
  template change shows up as a diff. tests/cases/Repository.Tests.ps1 fails
  when the two disagree. Edit the template, run this, commit both.

.PARAMETER Check
  Report drift and exit 1 instead of writing.
#>
[CmdletBinding()]
param([switch]$Check)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\lib\Vivac.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\lib\Deploy.psm1') -Force
$root = Split-Path -Parent $PSScriptRoot
$theme = Read-VivacTheme (Get-VivacDefaultTheme)
$drift = 0
foreach ($pkg in Get-ChildItem -LiteralPath (Join-Path $root 'templates') -Directory | Where-Object { $_.Name -notin 'wallpaper', 'brand' }) {
    foreach ($f in Get-ThemedRender $theme $pkg.Name) {
        $out = Join-Path $root "dotfiles\$($pkg.Name)\$($f.Relative)"
        $same = (Test-Path -LiteralPath $out) -and ([IO.File]::ReadAllText($out) -ceq $f.Text)
        if ($same) { continue }
        $drift++
        if ($Check) { "drift: dotfiles\$($pkg.Name)\$($f.Relative)" }
        else { Write-VivacFile -Path $out -Text $f.Text; "rendered: dotfiles\$($pkg.Name)\$($f.Relative)" }
    }
}
$keys = Join-Path $root 'docs\keys.md'
$text = Get-VivacKeysMarkdown
if (-not (Test-Path -LiteralPath $keys) -or [IO.File]::ReadAllText($keys) -cne $text) {
    $drift++
    if ($Check) { 'drift: docs\keys.md' } else { Write-VivacFile -Path $keys -Text $text; 'rendered: docs\keys.md' }
}
if ($Check -and $drift) { exit 1 }
