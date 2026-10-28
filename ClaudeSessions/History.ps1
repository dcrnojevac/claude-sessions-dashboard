# History search: what was said in every session Claude Code still keeps, extracted once per transcript change into
# %LOCALAPPDATA%\ClaudeSessions\history.

$ClaudeHistoryPath = Join-Path $ClaudeDataPath 'history'
$InjectedTagPattern = '<(system-reminder|local-command-stdout|local-command-stderr|local-command-caveat|command-name|command-message|command-args|task-notification)>[\s\S]*?</\1>'

# One regex per word or "quoted phrase". A term starting with a letter or digit must start where a word starts: after a
# non-letter, or at a capital inside a code name, so "notifier" finds EtlRunNotifier and "part" finds partition, but "rent" does
# not find current. Only the term itself ignores case; the capital check needs the text's real case.
function ConvertTo-ClaudeSearchPattern([string]$Query)
{
    foreach ($termMatch in [regex]::Matches($Query, '"([^"]+)"|(\S+)'))
    {
        $term = ($termMatch.Groups[1].Success ? $termMatch.Groups[1].Value : $termMatch.Groups[2].Value).Trim()

        if (-not $term)
            { continue }

        $wordStart = if ($term -match '^[\p{L}\p{N}]') { '(?:(?<![\p{L}\p{N}])|(?<=\p{Ll})(?=\p{Lu}))' } else { '' }
        $escapedTerm = [regex]::Escape($term) -replace '\\ ', '\s+'

        [regex]::new("$wordStart(?i:$escapedTerm)")
    }
}

# Untyped so a missing parent ($null) passes through as missing; PowerShell cannot convert $null to a JsonElement.
function Get-JsonProperty($Element, [string]$Name)
{
    [System.Text.Json.JsonElement]$value = [System.Text.Json.JsonElement]::new()

    if ($Element -is [System.Text.Json.JsonElement] -and $Element.ValueKind -eq 'Object' -and $Element.TryGetProperty($Name, [ref]$value))
        { return $value }
}

# The message's own text: a plain string, or its text blocks; tool calls, tool output, thinking and images are skipped.
function Read-ClaudeMessageText([string]$Line)
{
    try
    {
        $document = [System.Text.Json.JsonDocument]::Parse($Line)
    }
    catch
    {
        return
    }

    try
    {
        $content = Get-JsonProperty (Get-JsonProperty $document.RootElement 'message') 'content'

        if ($null -eq $content)
            { return }

        if ($content.ValueKind -eq 'String')
            { return $content.GetString() }

        if ($content.ValueKind -ne 'Array')
            { return }

        $blockTexts = foreach ($block in $content.EnumerateArray())
        {
            $text = Get-JsonProperty $block 'text'

            if ([string](Get-JsonProperty $block 'type') -eq 'text' -and $text.ValueKind -eq 'String')
                { $text.GetString() }
        }

        $blockTexts -join "`n"
    }
    finally
    {
        $document.Dispose()
    }
}

# Your prompts and Claude's text replies, without what Claude Code injects into the conversation (CLAUDE.md, memory, system
# reminders, command output), tool calls and tool output, so a search matches what was actually discussed.
function Read-ClaudeTranscriptText([string]$Path)
{
    $extract = [pscustomobject]@{ text = $null; cwd = $null; branch = $null; aiTitle = $null; customTitle = $null; firstPrompt = $null }
    $texts = [System.Collections.Generic.List[string]]::new()
    $reader = [IO.StreamReader]::new([IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'))

    try
    {
        while ($null -ne ($line = $reader.ReadLine()))
        {
            if ($line -like '*"isSidechain":true*')
                { continue }

            $branchMatch = [regex]::Match($line, '"gitBranch":"([^"]*)"')

            if ($branchMatch.Success)
                { $extract.branch = $branchMatch.Groups[1].Value }

            if (-not $extract.cwd)
            {
                $cwdMatch = [regex]::Match($line, '"cwd":"((?:[^"\\]|\\.)*)"')

                if ($cwdMatch.Success)
                    { $extract.cwd = [regex]::Unescape($cwdMatch.Groups[1].Value) }
            }

            if ($line -like '*"type":"ai-title"*')
                { $extract.aiTitle = (Select-LastTranscriptRecord @($line) 'ai-title').aiTitle ?? $extract.aiTitle }
            elseif ($line -like '*"type":"custom-title"*')
                { $extract.customTitle = (Select-LastTranscriptRecord @($line) 'custom-title').customTitle ?? $extract.customTitle }
            elseif ($line -like '*"type":"user"*' -and $line -notlike '*"type":"tool_result"*' -and $line -notlike '*"isMeta":true*' -and $line -notlike '*"isCompactSummary":true*')
            {
                $prompt = [regex]::Replace("$(Read-ClaudeMessageText $line)", $InjectedTagPattern, '').Trim()

                if (-not $prompt -or $prompt.StartsWith('[Request interrupted') -or $prompt.StartsWith('Caveat:'))
                    { continue }

                $texts.Add($prompt)
                $extract.firstPrompt ??= $prompt.Substring(0, [Math]::Min(200, $prompt.Length))
            }
            elseif ($line -like '*"type":"assistant"*' -and $line -like '*"type":"text"*')
            {
                $reply = Read-ClaudeMessageText $line

                if ($reply)
                    { $texts.Add($reply) }
            }
        }
    }
    finally
    {
        $reader.Dispose()
    }

    $extract.text = $texts -join "`n"
    $extract
}

# Every word and "quoted phrase" must appear, in any order, in the session's title or text. Running or pinned sessions come back as
# their live entries, the rest as stopped ones, newest first.
function Search-ClaudeHistory([string]$Query)
{
    $termPatterns = @(ConvertTo-ClaudeSearchPattern $Query)

    if ($termPatterns.Count -eq 0)
        { return }

    $history = Update-ClaudeHistory
    $labels = Get-ClaudeLabel
    $liveSessions = @{}

    foreach ($session in Get-ClaudeSession)
        { $liveSessions[$session.sessionId] = $session }

    $matchingSessions = foreach ($entry in $history.Values)
    {
        $text = [IO.File]::ReadAllText((Join-Path $ClaudeHistoryPath "$($entry.sessionId).txt"))
        $claudeTitle = $entry.customTitle ?? $entry.aiTitle
        $title = $labels[$entry.sessionId] ?? $claudeTitle ?? $entry.firstPrompt ?? $entry.sessionId
        $searchedText = "$title`n$text"

        if (@($termPatterns | Where-Object { -not $_.IsMatch($searchedText) }).Count -gt 0)
            { continue }

        $firstMatch = $termPatterns[0].Match($text)
        $position = if ($firstMatch.Success) { $firstMatch.Index } else { -1 }
        $snippetStart = [Math]::Max(0, $position - 60)
        $snippet = if ($position -ge 0) { $text.Substring($snippetStart, [Math]::Min(200, $text.Length - $snippetStart)) } else { $entry.firstPrompt }
        $snippet = (($snippetStart -gt 0 ? '...' : '') + ($snippet -replace '\s+', ' ')).Trim()
        $liveSession = $liveSessions[$entry.sessionId]

        if ($liveSession)
        {
            $liveSession | Add-Member -NotePropertyName snippet -NotePropertyValue $snippet -PassThru -Force
            continue
        }

        [pscustomobject]@{
            sessionId = $entry.sessionId
            name = $title
            cwd = $entry.cwd
            kind = 'stopped'
            pinned = $false
            running = $false
            label = $labels[$entry.sessionId]
            claudeTitle = $claudeTitle
            title = $title
            branch = $entry.branch
            lastActive = [datetime]::new($entry.lastWriteUtcTicks, 'Utc').ToLocalTime()
            snippet = $snippet
        }
    }

    $matchingSessions | Sort-Object lastActive -Descending
}

# The text in plain and bold runs, bold wherever a search term matches, so a result's snippet shows why it matched.
function Split-ClaudeSearchMatchText([string]$Text, [string]$Query)
{
    $isBold = [bool[]]::new($Text.Length)

    foreach ($termPattern in ConvertTo-ClaudeSearchPattern $Query)
    {
        foreach ($termMatch in $termPattern.Matches($Text))
            { [Array]::Fill($isBold, $true, $termMatch.Index, $termMatch.Length) }
    }

    $runStart = 0

    for ($position = 1; $position -le $Text.Length; $position++)
    {
        if ($position -lt $Text.Length -and $isBold[$position] -eq $isBold[$runStart])
            { continue }

        [pscustomobject]@{ text = $Text.Substring($runStart, $position - $runStart); isBold = $isBold[$runStart] }
        $runStart = $position
    }
}

# Re-reads only transcripts whose size or write time changed. Each session's text gets its own file, so a search reads plain text
# instead of parsing JSON; sessions whose transcript is gone drop out.
function Update-ClaudeHistory
{
    $indexPath = Join-Path $ClaudeHistoryPath 'index.json'
    $previousIndex = (Read-ClaudeJsonFile $indexPath -AsHashtable) ?? @{}
    $index = @{}
    $transcripts = @(Get-ChildItem "$HOME\.claude\projects\*\*.jsonl")

    # No transcripts at all means Claude Code moved or renamed them, not that every session expired at once.
    if ($transcripts.Count -eq 0 -and $previousIndex.Count -gt 0)
        { throw "No transcripts under $HOME\.claude\projects; Claude Code may have moved them, so the search cache is left as it is." }

    foreach ($transcript in $transcripts)
    {
        $sessionId = $transcript.BaseName
        $textPath = Join-Path $ClaudeHistoryPath "$sessionId.txt"
        $entry = $previousIndex[$sessionId]
        $isCurrent = $entry -and $entry.length -eq $transcript.Length -and $entry.lastWriteUtcTicks -eq $transcript.LastWriteTimeUtc.Ticks

        if (-not $isCurrent -or -not (Test-Path -LiteralPath $textPath))
        {
            $extract = Read-ClaudeTranscriptText $transcript.FullName
            Save-ClaudeFile $textPath $extract.text

            $entry = [ordered]@{
                sessionId = $sessionId
                length = $transcript.Length
                lastWriteUtcTicks = $transcript.LastWriteTimeUtc.Ticks
                cwd = $extract.cwd
                branch = $extract.branch
                aiTitle = $extract.aiTitle
                customTitle = $extract.customTitle
                firstPrompt = $extract.firstPrompt
            }
        }

        $index[$sessionId] = $entry
    }

    foreach ($sessionId in @($previousIndex.Keys | Where-Object { -not $index.Contains($_) }))
        { Remove-ClaudeFile (Join-Path $ClaudeHistoryPath "$sessionId.txt") }

    Save-ClaudeFile $indexPath (ConvertTo-Json -InputObject $index -Depth 3)
    $index
}
