# The clipboard panel: what is judged a secret (the Linux panel's patterns, so
# a text is one on both sides), which chip an entry falls under, what a search
# may match, and that a secret is never drawn.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Import-Module (Join-Path $root 'lib\ClipLogic.psm1') -Force
Import-Module (Join-Path $root 'lib\Surfaces.psm1') -Force
$surfaces = Get-Module Surfaces | Select-Object -First 1

function Get-Tree($o) {
    $o
    foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($o)) { if ($c -is [Windows.DependencyObject]) { Get-Tree $c } }
}
function Get-Texts($root) { @(Get-Tree $root | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object { if ($_.Inlines.Count -gt 1) { (@($_.Inlines | ForEach-Object { $_.Text }) -join '') } else { $_.Text } }) }

Case 'what looks like a secret is judged on the text alone' {
    foreach ($secret in 'ghp_abcdefghijklmnopqrstuvwxyz0123456789', 'password: hunter2', 'API_KEY=abc123', 'Authorization: Bearer abcdefgh12345678',
        '4111 1111 1111 1111', 'Xk9!mQ2#vL8@pR4$', "-----BEGIN RSA PRIVATE KEY-----`nMIIE", 'eyJhbGciOiJI.eyJzdWIiOiIx.abcdefghijk') {
        Assert-True (Test-ClipLooksSecret $secret) "should be a secret: $secret"
    }
    foreach ($plain in 'Resumen de la reunion del lunes', 'https://wiki.archlinux.org/title/Hyprland', 'systemctl --user restart waybar', 'Cancion de cuna',
        '/home/user/some/long/path-with-Mixed_chars1', '4111 1111 1111 1112', 'deadbeef', '') {
        Assert-True (-not (Test-ClipLooksSecret $plain)) "should be plain: $plain"
    }
}
Case 'an entry knows its first line, its counts and its chip' {
    $text = New-ClipEntry 'text' "Resumen de la reunion`n- Revisar presupuesto`n- Llamar a Ana"
    Assert-Equal 'Resumen de la reunion' $text.First
    Assert-Equal 3 $text.Lines
    Assert-Equal 'text' (Get-ClipKind $text)
    Assert-Equal 'link' (Get-ClipKind (New-ClipEntry 'text' 'https://example.org/a?b=1'))
    Assert-Equal 'text' (Get-ClipKind (New-ClipEntry 'text' "https://example.org/a`nand more")) 'a link among other lines is text'
    Assert-Equal 'private' (Get-ClipKind (New-ClipEntry 'text' 'ghp_abcdefghijklmnopqrstuvwxyz0123456789'))
    $img = [Windows.Media.Imaging.BitmapSource]::Create(4, 3, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, (New-Object byte[] 48), 16)
    $pic = New-ClipEntry 'image' '' $img
    Assert-Equal 'image' (Get-ClipKind $pic)
    Assert-Equal '4x3' "$($pic.Width)x$($pic.Height)"
    $mask = Get-ClipMask
    Assert-Equal 8 $mask.Length 'always eight, whatever the secret'
    Assert-Equal $mask (Get-ClipShown (New-ClipEntry 'text' 'password: x')) 'a secret is drawn as the mask'
}
Case 'counters and chips cover every entry' {
    $e = @((New-ClipEntry 'text' 'hola'), (New-ClipEntry 'text' 'adios'), (New-ClipEntry 'text' 'https://a.b/c'), (New-ClipEntry 'text' 'password: x'))
    $n = Get-ClipCounts $e
    Assert-Equal '4,2,1,0,1' (($n['all'], $n['text'], $n['link'], $n['image'], $n['private']) -join ',')
    Assert-Equal 1 @(Select-ClipByKind $e 'private').Count
    Assert-Equal 4 @(Select-ClipByKind $e 'all').Count
}
Case 'a search ignores case and accents and never finds a secret or a picture' {
    $e = @((New-ClipEntry 'text' 'Canci' + [char]0x00F3 + 'n de cuna'), (New-ClipEntry 'text' 'password: cuna123'), (New-ClipEntry 'text' 'otra cosa'))
    $e[0] = New-ClipEntry 'text' "Canci$([char]0x00F3)n de cuna"
    $found = @(Select-ClipFiltered $e 'CANCION')
    Assert-Equal 1 $found.Count 'case and accents ignored'
    Assert-Equal 1 @(Select-ClipFiltered $e 'cuna').Count 'the secret holding "cuna" is not found'
    Assert-Equal 3 @(Select-ClipFiltered $e '   ').Count 'an empty needle keeps everything'
}

Case 'the panel counts its chips, masks a secret everywhere and offers the selected entry' {
    $secret = 'ghp_abcdefghijklmnopqrstuvwxyz0123456789'
    & $surfaces {
        param($secret)
        $script:ClipHistory.Clear()
        foreach ($t in 'Resumen de la reunion', $secret, 'https://a.b/c', 'systemctl --user restart waybar') { $script:ClipHistory.Add((New-ClipEntry 'text' $t)) }
    } $secret
    $w = Show-Clipboard -NoShow
    $texts = Get-Texts $w
    Assert-True (-not ($texts | Where-Object { $_ -and $_.Contains($secret) })) 'the secret is on no text of the panel'
    Assert-True ($texts -contains (Get-ClipMask)) 'the mask stands in for it'
    $chips = @(Get-Tree $w | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Tag -is [hashtable] -and $_.Tag.ContainsKey('Kind') })
    Assert-Equal 5 $chips.Count 'all, text, links, images, private'
    $counts = @($chips | ForEach-Object { $_.Tag.Count.Text }) -join ','
    Assert-Equal '4,2,1,0,1' $counts 'each chip carries its counter'
    Assert-Equal (& $surfaces { T 'clip.count' @('4') }) $w.FindName('Subtitle').Text
    Assert-Equal 4 $w.FindName('Rows').Children.Count 'a row per entry'
    $w.Close()
    & $surfaces { $script:ClipHistory.Clear() }
}
Case 'an empty history says so' {
    & $surfaces { $script:ClipHistory.Clear() }
    $w = Show-Clipboard -NoShow
    Assert-Equal 1 $w.FindName('Rows').Children.Count
    Assert-Equal (& $surfaces { T 'clip.none' }) $w.FindName('Rows').Children[0].Text
    $w.Close()
}
Complete-Cases
