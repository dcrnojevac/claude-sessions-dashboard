# The optional task tracker: TRACKER.md (In Progress, Next, Planned, Low Priority), archive.md and items\<id>.md in ~\.claude\tracker, or the
# folder settings.json names in trackerPath. Sessions and people edit these files by hand, so they are only read, and a line that
# does not parse comes back as its raw text instead of failing the rest.

$TrackerIdPattern = '[a-z0-9]+(?:-[a-z0-9]+)*'
$TrackerDatePattern = '\d{4}-\d{2}-\d{2}'

# The history is "Added <date>" followed by one "<event> <date>" per move. A line without an Added stamp falls back to the last
# run of stamps that starts a sentence.
$TrackerHistoryPattern = "(?<![\p{L}])Added $TrackerDatePattern(?:,\s*[A-Za-z]+(?: [A-Za-z]+)* $TrackerDatePattern)*\.?"
$TrackerStampRunPattern = "(?<=^|\.\s+)[A-Za-z]+(?: [A-Za-z]+)* $TrackerDatePattern(?:,\s*[A-Za-z]+(?: [A-Za-z]+)* $TrackerDatePattern)*\.?"

# One line: "- [id] Title. Repo: name. After: [other-id]. Trigger: text. → items/id.md. Added 2026-01-05, planned 2026-01-09."
# After can repeat and holds ids, an outside event, or both. In archive.md the outcome follows the history. Only a bullet that
# starts with a kebab-case [id] is an item; anything else comes back with id $null and its raw text.
function ConvertFrom-ClaudeTrackerLine([string]$Line, [string]$Section)
{
    $item = [pscustomobject]@{
        raw = $Line.Trim()
        section = $Section
        id = $null
        title = $null
        repo = $null
        after = @()
        afterState = $null
        trigger = $null
        detailsLink = $null
        detailsPath = $null
        stamps = @()
        latestStamp = $null
        outcome = $null
    }

    $itemMatch = [regex]::Match($item.raw, "^[-*]\s+\[($TrackerIdPattern)\](?:\s+(.*))?$")

    if (-not $itemMatch.Success)
        { return $item }

    $item.id = $itemMatch.Groups[1].Value
    $text = $itemMatch.Groups[2].Value
    $historyMatch = [regex]::Matches($text, $TrackerHistoryPattern) | Select-Object -Last 1
    $historyMatch ??= [regex]::Matches($text, $TrackerStampRunPattern) | Select-Object -Last 1

    if ($historyMatch)
    {
        $item.stamps = @(
            foreach ($stampMatch in [regex]::Matches($historyMatch.Value, "([A-Za-z]+(?: [A-Za-z]+)*) ($TrackerDatePattern)"))
            {
                $date = [datetime]::MinValue
                $isDate = [datetime]::TryParseExact($stampMatch.Groups[2].Value, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, 'None', [ref]$date)

                [pscustomobject]@{ text = $stampMatch.Value; event = $stampMatch.Groups[1].Value; date = $isDate ? $date : $null }
            }
        )
        $outcome = $text.Substring($historyMatch.Index + $historyMatch.Length).Trim()
        $item.latestStamp = $item.stamps[-1]
        $item.outcome = if ($outcome) { $outcome }
        $text = $text.Substring(0, $historyMatch.Index)
    }

    # A keyword inside `code` (an even number of backticks before it means outside) is part of the text, and "->" starts a clause
    # only before items/, so an arrow in a title stays in the title.
    $clauses = $text -split '\s*(?<=^[^`]*(?:`[^`]*`[^`]*)*)(?=(?<![\p{L}])(?:After|Trigger|Repo):|(?:→|->)\s*items/)'
    $item.title = $clauses[0].Trim().TrimEnd('.').Trim()

    foreach ($clause in $clauses | Select-Object -Skip 1)
    {
        $value = ($clause -replace '^(?:After:|Trigger:|Repo:|→|->)\s*', '').Trim().TrimEnd('.').Trim()

        if ($clause.StartsWith('After:'))
            { $item.after += @(ConvertFrom-ClaudeTrackerAfter $value) }
        elseif ($clause.StartsWith('Trigger:'))
            { $item.trigger = ($item.trigger, $value | Where-Object { $_ }) -join '; ' }
        elseif ($clause.StartsWith('Repo:'))
            { $item.repo = $value }
        elseif ($value -match '^items/[\w.-]+\.md$')
            { $item.detailsLink = $value }
    }

    $item
}

# Each [id] is a link to another item; whatever text is left once they and the commas or "and" between them are gone is an
# outside event.
function ConvertFrom-ClaudeTrackerAfter([string]$Value)
{
    $idMatches = [regex]::Matches($Value, "\[($TrackerIdPattern)\]")

    foreach ($idMatch in $idMatches)
        { [pscustomobject]@{ id = $idMatch.Groups[1].Value; event = $null; state = $null } }

    $eventText = $Value

    if ($idMatches.Count -gt 0)
    {
        $separator = '(?:\s|[,;]|\band\b|\bor\b)*'
        $eventText = [regex]::Replace($Value, "\[$TrackerIdPattern\]", ' ') -replace "^$separator", '' -replace "$separator$", ''
    }

    if ($eventText.Trim())
        { [pscustomobject]@{ id = $null; event = $eventText.Trim(); state = 'event' } }
}

# "today", "1 day", "12 days": how long ago an item's last stamp was.
function Format-ClaudeDaysSince($Date)
{
    if (-not $Date)
        { return }

    $days = [int]((Get-Date).Date - $Date.Date).TotalDays

    switch ($days)
    {
        { $_ -le 0 } { 'today' }
        1 { '1 day' }
        default { "$days days" }
    }
}

# A missing folder or TRACKER.md is the normal case for most users: isSetUp is false and there are no items, never an error.
# Each After link's state, archived items' included, is open, archived, missing (no such id anywhere) or event; an item's
# afterState sums them up, blocked by an open or unknown id first, then waiting on an outside event, else unblocked.
function Get-ClaudeTracker([string]$Path)
{
    $tracker = [pscustomobject]@{ path = $Path; isSetUp = $false; items = @(); archivedItems = @() }

    if (-not (Test-ClaudeTracker $Path))
        { return $tracker }

    $archivePath = Join-Path $Path 'archive.md'
    $tracker.isSetUp = $true
    $tracker.items = @(Read-ClaudeTrackerFile (Join-Path $Path 'TRACKER.md'))
    $tracker.archivedItems = if (Test-Path -LiteralPath $archivePath -PathType Leaf) { @(Read-ClaudeTrackerFile $archivePath 'Archive') } else { @() }

    $openIds = @{}
    $archivedIds = @{}

    foreach ($item in $tracker.items | Where-Object id)
        { $openIds[$item.id] ??= $item }

    foreach ($item in $tracker.archivedItems | Where-Object id)
        { $archivedIds[$item.id] ??= $item }

    foreach ($item in @($tracker.items) + @($tracker.archivedItems) | Where-Object id)
    {
        foreach ($link in $item.after | Where-Object id)
            { $link.state = if ($openIds.Contains($link.id)) { 'open' } elseif ($archivedIds.Contains($link.id)) { 'archived' } else { 'missing' } }

        $states = @($item.after.state)
        $item.afterState = if ($states -contains 'open') { 'blocked' }
            elseif ($states -contains 'missing') { 'unknown' }
            elseif ($states -contains 'event') { 'waiting' }
            elseif ($states) { 'unblocked' }

        $detailsPath = Join-Path $Path ($item.detailsLink ?? "items/$($item.id).md")

        if (Test-Path -LiteralPath $detailsPath -PathType Leaf)
            { $item.detailsPath = $detailsPath }
    }

    $tracker
}

# settings.json's trackerPath, else ~\.claude\tracker.
function Get-ClaudeTrackerPath($Settings)
{
    if ($Settings.trackerPath)
        { return $Settings.trackerPath }

    Join-Path $HOME '.claude\tracker'
}

# "## Section" headings set the section, and bullets are items. Other text under a heading comes back raw, so a line that lost
# its bullet still shows; text before the first heading (the title, archive.md's intro) is skipped. Read shared, since a session
# may be writing the file.
function Read-ClaudeTrackerFile([string]$Path, [string]$Section)
{
    $reader = [IO.StreamReader]::new([IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'), [Text.Encoding]::UTF8)
    $isUnderHeading = $false

    try
    {
        while ($null -ne ($line = $reader.ReadLine()))
        {
            $headingMatch = [regex]::Match($line, '^##\s+(.+?)\s*#*\s*$')

            if ($headingMatch.Success)
            {
                $Section = $headingMatch.Groups[1].Value
                $isUnderHeading = $true
            }
            elseif ($line -match '^\s*[-*]\s' -or ($isUnderHeading -and $line.Trim() -and $line -notmatch '^#'))
            {
                ConvertFrom-ClaudeTrackerLine $line $Section
            }
        }
    }
    finally
    {
        $reader.Dispose()
    }
}

function Read-ClaudeTrackerDetails([string]$Path)
{
    $reader = [IO.StreamReader]::new([IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite'), [Text.Encoding]::UTF8)

    try
    {
        $reader.ReadToEnd()
    }
    finally
    {
        $reader.Dispose()
    }
}

# The text in plain and bold runs: **text** without its markers, and an [id] the tracker knows with its brackets. The rest of the
# Markdown stays as written, and code spans and fenced blocks are plain throughout, so ** or [name] in code is only text.
function Split-ClaudeTrackerBoldText([string]$Text, [string[]]$KnownIds)
{
    $knownIdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($KnownIds | Where-Object { $_ }))
    $boldPattern = '(?s)```.*?```|`[^`\r\n]*`|\*\*(?=\S)(?<bold>[^\r\n]+?)(?<=\S)\*\*|\[(?<id>' + $TrackerIdPattern + ')\]'
    $plainStart = 0

    foreach ($match in [regex]::Matches($Text, $boldPattern))
    {
        $boldText = if ($match.Groups['bold'].Success) { $match.Groups['bold'].Value }
            elseif ($match.Groups['id'].Success -and $knownIdSet.Contains($match.Groups['id'].Value)) { $match.Value }

        if (-not $boldText)
            { continue }

        if ($match.Index -gt $plainStart)
            { [pscustomobject]@{ text = $Text.Substring($plainStart, $match.Index - $plainStart); isBold = $false } }

        [pscustomobject]@{ text = $boldText; isBold = $true }
        $plainStart = $match.Index + $match.Length
    }

    if ($plainStart -lt $Text.Length)
        { [pscustomobject]@{ text = $Text.Substring($plainStart); isBold = $false } }
}

function Test-ClaudeTracker([string]$Path)
{
    $Path -and (Test-Path -LiteralPath (Join-Path $Path 'TRACKER.md') -PathType Leaf)
}
