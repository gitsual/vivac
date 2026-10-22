<#
.SYNOPSIS
  Run every gate.

.DESCRIPTION
  Each file in tests/cases runs in a fresh Windows PowerShell, so no module
  state or environment variable leaks from one gate into the next. The gates
  never touch the real profile: the ones that deploy do it into a scratch
  directory (see New-TempProfile in tests/Harness.psm1).

  Author-run, not CI: like the source repository, this is run by hand
  before publishing. Nothing re-runs it on each commit.

.PARAMETER Filter
  Run only the case files whose name matches.
#>
[CmdletBinding()]
param([string]$Filter = '')
Set-StrictMode -Version 2.0
$root = Split-Path -Parent $PSScriptRoot
$failed = @()
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'tests\cases') -Filter '*.Tests.ps1' | Where-Object { $_.Name -match $Filter } | Sort-Object Name)
$watch = [Diagnostics.Stopwatch]::StartNew()
foreach ($f in $files) {
    Write-Host "== $($f.BaseName)" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $f.BaseName }
}
$passed = $files.Count - $failed.Count
Write-Host ''
Write-Host ("{0}/{1} gate files passed in {2:N0}s" -f $passed, $files.Count, $watch.Elapsed.TotalSeconds)
if ($failed.Count) {
    Write-Host ("failed: " + ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
