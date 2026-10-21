<#
.SYNOPSIS
  Copy what both systems share (shared\data\) into linux\data\ and
  windows\data\.

.DESCRIPTION
  Each side keeps its own copy so it deploys on its own; this is the only way
  those copies change. The same as shared/sync.sh, for Windows.

    (none)    copy, and say what changed
    -Check    change nothing; exit 1 and name every copy that differs (what
              both sides' gates run)
#>
[CmdletBinding()]
param([switch]$Check)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$root = Split-Path -Parent $here
$data = Join-Path $here 'data'
$drift = $false
foreach ($src in Get-ChildItem -LiteralPath $data -Recurse -File | Sort-Object FullName) {
    $rel = $src.FullName.Substring($here.Length + 1)
    foreach ($side in 'linux', 'windows') {
        $dest = Join-Path (Join-Path $root $side) $rel
        if ((Test-Path -LiteralPath $dest) -and
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes($src.FullName)) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($dest)))) { continue }
        if ($Check) {
            [Console]::Error.WriteLine("drift: $side\$rel differs from shared\$rel")
            $drift = $true
        } else {
            [void](New-Item -ItemType Directory -Force -Path (Split-Path $dest))
            Copy-Item -LiteralPath $src.FullName -Destination $dest -Force
            "updated $side\$rel"
        }
    }
}
if ($drift) { exit 1 }
exit 0
