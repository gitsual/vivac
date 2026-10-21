# vivac ask (lib/Ask.psm1, lib/AskPanel.psm1) against a fake Ollama on the
# loopback (tests/fake-ollama.ps1): the streamed pieces come back as one
# answer, the first listed model is taken when none is set, a server error, a
# stall, an error inside the stream and a closed port each end with a clear
# message, and ask_url off this machine is refused unless ask_allow_lan says
# otherwise (a public address always). The inbox summary reads at most the
# first KiB of a file and never follows a link out of the inbox. Nothing here
# reaches the screen or the clipboard: the panel is built, not shown.
Import-Module (Join-Path $PSScriptRoot '..\Harness.psm1') -Force
$root = Get-RepoRoot
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$dir = New-TempProfile
Import-Module (Join-Path $root 'lib\Vivac.psm1') -Force
Set-VivacSetting language en
Import-Module (Join-Path $root 'lib\Ask.psm1') -Force
[void](Import-VivacStrings 'en')
$scratch = Join-Path $dir 'scratch'
$state = Join-Path $dir 'fake'
[void](New-Item -ItemType Directory -Force -Path $scratch, $state)

$port = Get-Random -Minimum 40000 -Maximum 60000
$fake = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    "`"$(Join-Path $root 'tests\fake-ollama.ps1')`"", '-Port', $port, '-State', "`"$state`"")
$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path -LiteralPath (Join-Path $state 'ready')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
$loop = [Net.IPAddress]::Loopback.ToString()
$ep = Get-VivacAskEndpoint "http://localhost:$port" $false
$hi = Get-VivacAskMessages @(@{ role = 'user'; content = 'hi' })
$hello = 'Hello w' + [char]0xF6 + 'rld'

try {
    Case 'the fake Ollama is up' { Assert-True (Test-Path -LiteralPath (Join-Path $state 'ready')) 'it did not start' }
    Case 'the ask settings: defaults, valid values, refusals' {
        $s = Read-VivacSettings
        Assert-Equal 'http://localhost:11434' $s['ask_url']
        Assert-Equal 'none' $s['ask_model']
        Assert-Equal 'false' $s['ask_allow_lan']
        Set-VivacSetting ask_url 'http://[::1]:11434'
        Set-VivacSetting ask_model 'qwen2.5:7b'
        Set-VivacSetting ask_allow_lan 'true'
        foreach ($bad in @(@('ask_url', 'ftp://localhost:1'), @('ask_url', 'http://localhost:1/api;x'), @('ask_allow_lan', 'yes'), @('ask_model', '-rf'))) {
            Assert-Throws { Set-VivacSetting $bad[0] $bad[1] } 'not a valid value'
        }
        Set-VivacSetting ask_url 'http://localhost:11434'; Set-VivacSetting ask_model 'none'; Set-VivacSetting ask_allow_lan 'false'
    }
    Case 'where the request may go: the loopback always, the LAN only when allowed, the internet never' {
        Assert-Equal $loop (Get-VivacAskEndpoint 'http://localhost:11434' $false).Address
        Assert-Equal "localhost:$port" $ep.Host
        Assert-Equal '[::1]' (Get-VivacAskEndpoint 'http://[::1]:11434' $false).Address
        Assert-Equal $loop (Get-VivacAskEndpoint "http://$($loop):11434" $false).Address
        $lan = '192.168.' + '1.20'
        Assert-Throws { Get-VivacAskEndpoint "http://$($lan):11434" $false } 'is not this machine'
        Assert-Equal $lan (Get-VivacAskEndpoint "http://$($lan):11434" $true).Address
        Assert-Throws { Get-VivacAskEndpoint 'http://ollama.example:11434' $false } 'is not this machine'
        Assert-Throws { Get-VivacAskEndpoint 'http://8.8.8.8:11434' $true } 'never sends anything to the internet'
        Assert-Throws { Get-VivacAskEndpoint 'http://[2606:4700::1111]:11434' $true } 'never sends anything to the internet'
        Assert-Throws { Get-VivacAskEndpoint "https://$($loop):11434" $false } 'must be http://HOST:PORT'
        Assert-Throws { Get-VivacAskEndpoint "http://$($loop):11434/v1" $false } 'must be http://HOST:PORT'
        Assert-Throws { Get-VivacAskEndpoint "http://$($loop):11434/?x=1" $false } 'must be http://HOST:PORT'
    }
    Case 'a streamed answer is put together, piece by piece, from the first listed model' {
        $m = Resolve-VivacAskModel $ep 'none'
        Assert-Equal 'fake:1b' $m.Name
        Assert-True $m.Chosen 'chosen, so the panel says so'
        Assert-Equal 'other:7b' (Resolve-VivacAskModel $ep 'other:7b').Name
        $pieces = New-Object System.Collections.ArrayList
        $answer = Get-VivacAskAnswer $ep $m.Name $hi { param($t) [void]$pieces.Add($t) } 20
        Assert-Equal $hello $answer
        Assert-Equal 3 $pieces.Count 'each piece as it came'
        $req = [IO.File]::ReadAllText((Join-Path $state 'request.json')) | ConvertFrom-Json
        Assert-Equal 'fake:1b' $req.model
        Assert-True $req.stream 'streamed'
        Assert-Equal 'system,user' (@($req.messages | ForEach-Object { $_.role }) -join ',')
        Assert-Equal 'hi' $req.messages[1].content
        Assert-Equal "localhost:$port" ([IO.File]::ReadAllText((Join-Path $state 'host'))) 'the Host is the name the user wrote'
    }
    Case 'failures are said: the server error, a stall, an error in the stream, a closed port, no models' {
        Assert-Throws { Get-VivacAskAnswer $ep 'missing' $hi $null 20 } "Ollama answered 404: model 'missing' not found"
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Assert-Throws { Get-VivacAskAnswer $ep 'stall' $hi $null 1 } 'sent nothing for 1 s'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 3.5) "the stall was waited out ($($watch.Elapsed.TotalSeconds) s)"
        Assert-Throws { Get-VivacAskAnswer $ep 'broken' $hi $null 20 } 'the model crashed'
        Assert-Throws { Get-VivacAskAnswer (Get-VivacAskEndpoint 'http://localhost:1' $false) 'fake:1b' $hi $null 5 } 'Ollama is not answering at'
        [IO.File]::WriteAllText((Join-Path $state 'empty'), 'yes')
        try { Assert-Throws { Resolve-VivacAskModel $ep 'none' } 'ollama pull' } finally { Remove-Item -LiteralPath (Join-Path $state 'empty') }
    }
    Case 'on its own thread: the pieces queue up, the answer and Done arrive, Stop cancels' {
        $job = Start-VivacAskJob 'chat' $ep 'fake:1b' $hi 20
        $deadline = (Get-Date).AddSeconds(15)
        while (-not $job.Done -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-True $job.Done 'done'
        Assert-Equal $null $job.Error
        $all = ''; $piece = $null
        while ($job.Queue.TryDequeue([ref]$piece)) { $all += $piece }
        Assert-Equal $hello $all
        Assert-Equal $all $job.Result
        $models = Start-VivacAskJob 'models' $ep 'none' @() 20
        $deadline = (Get-Date).AddSeconds(15)
        while (-not $models.Done -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-Equal 'fake:1b' $models.Result.Name
        $slow = Start-VivacAskJob 'chat' $ep 'stall' $hi 20
        Start-Sleep -Milliseconds 800
        Stop-VivacAskJob $slow
        $deadline = (Get-Date).AddSeconds(3)
        while (-not $slow.Done -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-True $slow.Done 'a stopped answer ends at once'
        Assert-True ($slow.Error -match 'stopped') "stopped: $($slow.Error)"
    }
    Case 'the clipboard as context: nothing for empty text, cut at the limit' {
        Assert-Equal $null (Get-VivacAskClipContext '   ')
        $c = Get-VivacAskClipContext "def f(x):`n    return x * 2"
        Assert-True ($c.Text -match '^<context source="clipboard">\n[\s\S]*return x \* 2\n</context>$') $c.Text
        $big = Get-VivacAskClipContext ('x' * 20000)
        Assert-True $big.Cut 'cut'
        Assert-Equal 16384 $big.Size
    }
    Case 'the inbox: names and sizes, the first KiB of text, no link or folder followed' {
        $box = Join-Path $scratch 'inbox'
        $outside = Join-Path $scratch 'outside'
        [void](New-Item -ItemType Directory -Force -Path $box, $outside, (Join-Path $box 'a folder'))
        [IO.File]::WriteAllText((Join-Path $outside 'away.txt'), 'OUTSIDE-TEXT')
        [IO.File]::WriteAllText((Join-Path $box 'notes.txt'), ('a' * 1024) + 'TAILMARK')
        [IO.File]::WriteAllText((Join-Path $box 'a folder\inside.txt'), 'INNER-TEXT')
        [IO.File]::WriteAllBytes((Join-Path $box 'blob.bin'), [byte[]](0, 1, 2, 98, 105, 110))
        # A junction needs no privilege; a file link does (Developer Mode), so
        # it is tried and left out where Windows refuses it.
        & cmd.exe /c mklink /J "$box\link-dir" "$outside" | Out-Null
        & cmd.exe /c mklink "$box\link.txt" "$outside\away.txt" 2>$null | Out-Null
        $out = Get-VivacAskInboxContext $box
        foreach ($name in 'notes.txt', 'a folder', 'blob.bin', 'link-dir') { Assert-True ($out -match [regex]::Escape("- $name")) "$name is not listed: $out" }
        Assert-True ($out -match 'link-dir: a link, not followed') 'a junction was not named as a link'
        if (Test-Path -LiteralPath "$box\link.txt") { Assert-True ($out -match 'link\.txt: a link, not followed') 'a file link was not named as one' }
        Assert-True ($out -match 'a folder: a folder, not opened') 'a folder was not named as one'
        Assert-True ($out -match '\(not text, not read\)') 'a binary file was not marked'
        Assert-True ($out -notmatch 'OUTSIDE-TEXT|INNER-TEXT') "read through a link or into a folder: $out"
        Assert-True ($out -notmatch 'TAILMARK') 'read past the first KiB'
        $kept = (@($out -split "`n" | Where-Object { $_ -like '  | *' }) -join '') -replace '[^a]', ''
        Assert-Equal 1024 $kept.Length 'the first KiB of the text file'
        $outer = Join-Path $scratch 'inbox-link'
        & cmd.exe /c mklink /J "$outer" "$box" | Out-Null
        Assert-Throws { Get-VivacAskInboxContext $outer } 'There is no inbox at'
        Assert-Throws { Get-VivacAskInboxContext (Join-Path $scratch 'nowhere') } 'There is no inbox at'
        Set-VivacSetting ask_url "http://localhost:$port"
        $dry = (Get-VivacAskDryRun 'inbox' '' $box) -join "`n"
        Assert-True ($dry -match "Would ask the first model Ollama lists at http://localhost:$port \($([regex]::Escape($loop)):$port\); nothing was sent") $dry
        Assert-True ($dry -match 'Summarise what arrived') 'the inbox request is the question'
        Set-VivacSetting ask_url 'http://localhost:11434'
    }
    Case 'saving never writes over a file unless the dialog asked' {
        $md = ConvertTo-VivacAskMarkdown 'fake:1b' @(@{ role = 'user'; content = 'hi' }, @{ role = 'assistant'; content = 'Hello' })
        Assert-True ($md -match '## You' -and $md -match '## fake:1b') $md
        $file = Join-Path $scratch 'talk.md'
        Save-VivacAskConversation $file $md
        Assert-Throws { Save-VivacAskConversation $file 'other' } ''
        Assert-True ([IO.File]::ReadAllText($file) -match 'Hello') 'the first save is kept'
        Save-VivacAskConversation $file 'replaced' -Replace
        Assert-Equal 'replaced' ([IO.File]::ReadAllText($file))
    }
    Case 'the panel builds in every theme, titled vivac, and stays beside your work' {
        foreach ($name in Get-VivacCatalogue) {
            Set-VivacSetting theme $name
            Import-Module (Join-Path $root 'lib\AskPanel.psm1') -Force
            $w = Show-Ask -NoShow
            Assert-True ($w -is [Windows.Window]) 'a window'
            Assert-True ($w.Title -match '^vivac') 'titled vivac, so GlazeWM leaves it alone'
            Assert-True $w.Resources['vivac.keep'] 'it does not close when it loses the focus'
            $w.Close()
        }
    }
} finally {
    [IO.File]::WriteAllText((Join-Path $state 'stop'), 'yes')
    if ($fake -and -not $fake.WaitForExit(5000)) { Stop-Process -Id $fake.Id -Force -ErrorAction SilentlyContinue }
    # The links go first, by rmdir, which takes a junction and not its target.
    foreach ($j in (Join-Path $scratch 'inbox\link-dir'), (Join-Path $scratch 'inbox-link')) {
        if (Test-Path -LiteralPath $j) { & cmd.exe /c rmdir "$j" | Out-Null }
    }
    Remove-TempProfile $dir
}
Complete-Cases
