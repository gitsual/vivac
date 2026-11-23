# What the clipboard panel decides about an entry before it draws anything:
# its first line and counts, whether the text looks like a secret, which
# filter chip it belongs to, and what a search may match. Pure functions, no
# window: tests/cases/ClipPanel.Tests.ps1 runs them anywhere. The judgement
# of a secret is the Linux side's (linux/lib/vivacpanel/clipboard.py,
# looks_secret), pattern for pattern, so one text is a secret on both.

Set-StrictMode -Version 2.0

$script:ClipMask = ([string][char]0x2022) * 8   # always eight: its length must not tell the secret's
$script:ClipReadCap = 64 * 1024                  # characters of an entry judged

$script:ClipTokens = [regex]::new(
    '(?:\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bglpat-[A-Za-z0-9_-]{16,}' +
    '|\bsk-[A-Za-z0-9_-]{16,}|\b[sr]k_(?:live|test)_[A-Za-z0-9]{12,}|\bxox[abprs]-[A-Za-z0-9-]{10,}' +
    '|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{30,}|\bnpm_[A-Za-z0-9]{30,}' +
    '|\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}' +
    '|-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----)')
$script:ClipAssigned = [regex]::new(
    '(?i)\b[\w.-]*(?:pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key' +
    '|auth(?:orization)?|bearer|credential)[\w.-]*\s*[:=]\s*\S+')
$script:ClipBearer = [regex]::new('(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{8,}')
$script:ClipLink = [regex]::new('^(?:https?|ftp)://\S+$')

function Test-ClipLuhn([string]$Digits) {
    $total = 0
    $chars = $Digits.ToCharArray()
    [Array]::Reverse($chars)
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $d = [int][string]$chars[$i]
        if ($i % 2) { $d = if ($d -gt 4) { $d * 2 - 9 } else { $d * 2 } }
        $total += $d
    }
    $total % 10 -eq 0
}

# A password, token, key, credential assignment or card number, judged on the
# text alone: a false alarm only costs a masked row, a miss costs a leak.
function Test-ClipLooksSecret([string]$Text) {
    if (-not $Text) { return $false }
    if ($Text.Length -gt $script:ClipReadCap) { $Text = $Text.Substring(0, $script:ClipReadCap) }
    $body = $Text.Trim()
    if (-not $body) { return $false }
    if ($script:ClipTokens.IsMatch($body) -or $script:ClipAssigned.IsMatch($body) -or $script:ClipBearer.IsMatch($body)) { return $true }
    $digits = $body -replace '[ -]', ''
    if ($body -match '^[ \d-]{13,23}$' -and $digits.Length -ge 13 -and $digits.Length -le 19 -and (Test-ClipLuhn $digits)) { return $true }
    # One word with no meaning of its own: 8-64 characters mixing at least three
    # of lower, upper, digit and symbol; not a link or a path.
    if ($body -match '^\S{8,64}$' -and $body -notmatch '://' -and $body -notmatch '^(/|~|\./|\.\./)') {
        $classes = 0
        foreach ($re in '[a-z]', '[A-Z]', '\d', '[^\w\s]') { if ($body -cmatch $re) { $classes++ } }
        if ($classes -ge 3) { return $true }
        if ($body.Length -ge 40 -and $body -match '^[A-Za-z0-9+/=_-]+$' -and $body -notmatch '^[0-9a-fA-F]+$' -and
            $classes -ge 2 -and $body -cmatch '[A-Z]' -and $body -match '\d') { return $true }
    }
    $false
}

# An entry as the history keeps it: the text or the picture, and what the
# panel needs to describe it without reading the text again.
function New-ClipEntry([string]$Kind, [string]$Text = '', $Image = $null) {
    $e = [ordered]@{ Kind = $Kind; Text = $Text; Image = $Image; Key = ''; First = ''; Lines = 1; Chars = 0; Private = $false; Width = 0; Height = 0 }
    if ($Kind -eq 'image' -and $Image) {
        $e.Width = [int]$Image.PixelWidth; $e.Height = [int]$Image.PixelHeight
        $e.Key = "image:$($e.Width)x$($e.Height):$($Image.GetHashCode())"
    } else {
        $stripped = $Text.Trim()
        $all = @($stripped -split "`r?`n")
        $e.Key = $Text
        $e.Chars = $Text.Length
        $e.Lines = [Math]::Max(1, $all.Count)
        $e.First = [string](@($all | Where-Object { $_.Trim() })[0])
        $e.First = $e.First.Trim()
        $e.Private = Test-ClipLooksSecret $Text
    }
    [pscustomobject]$e
}

# The chip an entry belongs to: private (looks like a secret), image, link
# (one URL and nothing else) or text.
function Get-ClipKind($Entry) {
    if ($Entry.Private) { return 'private' }
    if ($Entry.Kind -eq 'image') { return 'image' }
    if ($Entry.Lines -eq 1 -and $script:ClipLink.IsMatch($Entry.First)) { return 'link' }
    'text'
}

$script:ClipKinds = @('all', 'text', 'link', 'image', 'private')
function Get-ClipKinds { $script:ClipKinds }

# An empty history arrives as nothing at all as often as an empty list.
function Get-ClipList($Entries) { @(@($Entries) | Where-Object { $null -ne $_ }) }

function Get-ClipCounts([object[]]$Entries) {
    $items = @(Get-ClipList $Entries)
    $n = [ordered]@{ all = $items.Count; text = 0; link = 0; image = 0; private = 0 }
    foreach ($e in $items) {
        $k = Get-ClipKind $e
        $n[$k] = [int]$n[$k] + 1
    }
    $n
}

function Select-ClipByKind([object[]]$Entries, [string]$Kind) {
    $items = @(Get-ClipList $Entries)
    if ($Kind -eq 'all') { return $items }
    @($items | Where-Object { (Get-ClipKind $_) -eq $Kind })
}

# Case and accents ignored, as the menu's search does.
function Get-ClipKey([string]$Text) {
    $d = $Text.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    $sb.ToString()
}

# Text entries containing the needle. A secret or a picture never matches, so
# typing cannot be used to feel one out.
function Select-ClipFiltered([object[]]$Entries, [string]$Needle) {
    $needle = Get-ClipKey $Needle.Trim()
    $items = @(Get-ClipList $Entries)
    if (-not $needle) { return $items }
    @($items | Where-Object { $_.Kind -eq 'text' -and -not $_.Private -and (Get-ClipKey $_.Text).Contains($needle) })
}

# What may be drawn for the entry: its first line, or the mask.
function Get-ClipShown($Entry) {
    if ($Entry.Private) { return $script:ClipMask }
    $Entry.First
}

function Get-ClipMask { $script:ClipMask }
