# The bar's own safety net. With the Windows taskbar hidden the bar is the
# only way back to a minimized window, so a bar that is gone or blank
# strands the session. Three guards, used by scripts/deploy.ps1 and
# bin/vivac-bar-watch.ps1:
#
#   Test-VivacBarFiles   a pack that would load blank is refused before it is
#                        written (module syntax, network imports, missing files)
#   bar.alive            the bar stamps it every half minute while it is really
#                        drawn (static/zebar/vivac/bar.js)
#   bar-last-good        a copy of the last pack seen drawn, put back when a
#                        new one does not draw after a restart

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Vivac.psm1')
Import-Module (Join-Path $PSScriptRoot 'Apps.psm1')

function Get-VivacBarPaths {
    $state = Join-Path $env:LOCALAPPDATA 'vivac'
    [pscustomobject]@{
        Pack     = Join-Path (Get-VivacTargetRoot 'zebar') 'vivac'
        Alive    = Join-Path $state 'bar.alive'
        LastGood = Join-Path $state 'bar-last-good'
    }
}

# The names an ES module exports, read off its text: declarations
# (export const/let/var/function/class NAME), lists (export { a, b as c }),
# and default.
function Get-ModuleExports([string]$Text) {
    $names = @()
    foreach ($m in [regex]::Matches($Text, '\bexport\s+(?:async\s+)?(?:function\*?|const|let|var|class)\s+([A-Za-z_$][\w$]*)')) { $names += $m.Groups[1].Value }
    foreach ($m in [regex]::Matches($Text, '\bexport\s*\{([^}]*)\}')) {
        foreach ($part in $m.Groups[1].Value -split ',') {
            $bits = $part.Trim() -split '\s+as\s+'
            if ($bits[-1].Trim()) { $names += $bits[-1].Trim() }
        }
    }
    if ($Text -match '\bexport\s+default\b') { $names += 'default' }
    $names
}

# What would keep the pack in $Dir from drawing, one line per problem; none
# means it may be deployed. Without node the module syntax goes unchecked,
# the rest still is.
function Test-VivacBarFiles([string]$Dir) {
    $problems = New-Object System.Collections.Generic.List[string]
    $packFile = Join-Path $Dir 'zpack.json'
    if (-not (Test-Path -LiteralPath $packFile)) { $problems.Add('zpack.json is missing'); return $problems.ToArray() }
    try { $pack = [IO.File]::ReadAllText($packFile) | ConvertFrom-Json } catch { $problems.Add("zpack.json: $($_.Exception.Message)"); return $problems.ToArray() }
    foreach ($w in @($pack.widgets)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Dir $w.htmlPath))) { $problems.Add("widget $($w.name): $($w.htmlPath) is missing") }
    }
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $tmp = $null
    if ($node) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vivac-bar-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [void](New-Item -ItemType Directory -Path $tmp)
    }
    try {
        foreach ($f in Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Extension -in '.js', '.html' }) {
            $text = [IO.File]::ReadAllText($f.FullName)
            # What a page loads: module imports, fetches, and src/href in HTML.
            $refs = [regex]::Matches($text, '(?:\bfrom\s+|\bimport\s*\(\s*|\bimport\s+|\bfetch\(\s*|\bsrc=|\bhref=)[''"]([^''"]+)[''"]')
            foreach ($m in $refs) {
                $ref = $m.Groups[1].Value
                if ($ref -match '^https?:') {
                    if ($m.Value -notmatch '^fetch') { $problems.Add("$($f.Name) loads $ref from the network") }
                    continue
                }
                if ($ref -notmatch '^\.{1,2}/') { continue }
                $target = Join-Path $Dir (($ref -replace '[?#].*$', '') -replace '/', '\')
                if (-not (Test-Path -LiteralPath $target)) { $problems.Add("$($f.Name) loads $ref, which is missing") }
            }
            # A name imported that the sibling does not export fails at link
            # time, which node --check never reaches, and blanks the bar alike.
            foreach ($m in [regex]::Matches($text, '\bimport\s*\{([^}]*)\}\s*from\s*[''"](\.{1,2}/[^''"]+)[''"]')) {
                $sibling = Join-Path $Dir ($m.Groups[2].Value -replace '/', '\')
                if (-not (Test-Path -LiteralPath $sibling)) { continue }
                $exported = Get-ModuleExports ([IO.File]::ReadAllText($sibling))
                foreach ($name in $m.Groups[1].Value -split ',') {
                    $n = ($name.Trim() -split '\s+as\s+')[0].Trim()
                    if ($n -and $exported -notcontains $n) { $problems.Add("$($f.Name) imports $n from $($m.Groups[2].Value), which does not export it") }
                }
            }
            if ($node -and $f.Extension -eq '.js') {
                $copy = Join-Path $tmp ($f.BaseName + '.mjs')
                [IO.File]::WriteAllText($copy, $text)
                $out = & $node.Source --check $copy 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $first = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match 'Error' } | Select-Object -First 1)
                    $problems.Add("$($f.Name) does not parse as a module: $($first -join '')")
                }
            }
        }
    } finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $problems.ToArray()
}

# When the bar last proved it was drawn, or $null.
function Get-VivacBarAliveTime {
    $p = (Get-VivacBarPaths).Alive
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    (Get-Item -LiteralPath $p).LastWriteTime
}

# Waits for a stamp newer than $Since; whether one came.
function Wait-VivacBarAlive([datetime]$Since, [int]$TimeoutSec = 40) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $t = Get-VivacBarAliveTime
        if ($t -and $t -gt $Since) { return $true }
        Start-Sleep -Milliseconds 500
    }
    $false
}

# Whether the pack on disk is the one seen drawn. A fresh stamp alone is not
# enough: Zebar does not reload, so a bar started before the files changed
# keeps stamping with the old code. The running Zebar must have started after
# the newest file was written, and stamped since, within the last minute.
function Test-VivacBarProven {
    $p = Get-VivacBarPaths
    $zebar = @(Get-Process -Name zebar -ErrorAction SilentlyContinue)
    if (-not $zebar.Count) { return $false }
    $started = ($zebar | Measure-Object -Property StartTime -Maximum).Maximum
    $newest = Get-ChildItem -LiteralPath $p.Pack -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $newest -or $newest.LastWriteTime -ge $started) { return $false }
    $aliveAt = Get-VivacBarAliveTime
    [bool]($aliveAt -and $aliveAt -gt $started -and (Get-Date) - $aliveAt -lt [TimeSpan]::FromSeconds(60))
}

# Keeps a copy of the pack as it is now. Only call this when
# Test-VivacBarProven says so, so the copy is one that works.
function Save-VivacBarLastGood {
    $p = Get-VivacBarPaths
    if (-not (Test-Path -LiteralPath $p.Pack)) { return $false }
    $tmp = "$($p.LastGood).new"
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $p.Pack -Destination $tmp -Recurse -Force
    Remove-Item -LiteralPath $p.LastGood -Recurse -Force -ErrorAction SilentlyContinue
    Rename-Item -LiteralPath $tmp -NewName (Split-Path -Leaf $p.LastGood)
    $true
}

# Whether the pack changed since the last good copy was taken.
function Test-VivacBarLastGoodStale {
    $p = Get-VivacBarPaths
    if (-not (Test-Path -LiteralPath $p.LastGood)) { return $true }
    $saved = (Get-Item -LiteralPath $p.LastGood).LastWriteTime
    $newest = Get-ChildItem -LiteralPath $p.Pack -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    [bool]($newest -and $newest.LastWriteTime -gt $saved)
}

# Puts the last good pack back and restarts the bar; whether there was one.
function Restore-VivacBarLastGood {
    $p = Get-VivacBarPaths
    if (-not (Test-Path -LiteralPath $p.LastGood)) { return $false }
    foreach ($f in Get-ChildItem -LiteralPath $p.LastGood -Recurse -File) {
        $dest = Join-Path $p.Pack ($f.FullName.Substring($p.LastGood.Length).TrimStart('\'))
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $dest))
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
    # The copy is not newer than itself: the restored pack must not count as
    # a change to save over it.
    (Get-Item -LiteralPath $p.LastGood).LastWriteTime = Get-Date
    [void](Restart-VivacBar)
    $true
}

Export-ModuleMember -Function *
