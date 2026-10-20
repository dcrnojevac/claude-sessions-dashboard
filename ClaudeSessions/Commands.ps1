# The cc* commands for the terminal; cchelp lists them.

$ListedSessions = @()

# Numbers refer to the last ccl or cch in this shell, so a session that became active in between cannot take another one's
# number. A stopped session from that list (a cch result, say) resolves to the listed entry, so it can still be opened or pinned.
function Resolve-ClaudeSession([string]$Target)
{
    $sessions = @(Get-ClaudeSession)

    if ($Target -match '^\d+$')
    {
        $number = [int]$Target

        if ($script:ListedSessions.Count -eq 0)
            { throw 'Numbers refer to the last ccl or cch in this tab; run one first.' }

        if ($number -lt 1 -or $number -gt $script:ListedSessions.Count)
            { throw "The last list had $($script:ListedSessions.Count) sessions; there is no #$number." }

        $listedSession = $script:ListedSessions[$number - 1]
        $currentSession = $sessions | Where-Object sessionId -eq $listedSession.sessionId

        if ($currentSession)
            { return $currentSession }

        if (-not $listedSession.running)
            { return $listedSession }

        throw "#$number from the last list is no longer running; run ccl again."
    }

    $pattern = [WildcardPattern]::Escape($Target)
    $matching = @($sessions | Where-Object { $_.title -like "*$pattern*" -or $_.name -like "*$pattern*" -or $_.sessionId -like "$pattern*" })
    $exactMatches = @($matching | Where-Object title -eq $Target)

    if ($matching.Count -eq 1)
        { return $matching[0] }

    if ($exactMatches.Count -eq 1)
        { return $exactMatches[0] }

    throw "'$Target' matches $($matching.Count) sessions; ccl lists them."
}

# Repo commands take no param block: PowerShell would bind Claude's own flags to it (-r to -Repo, --bg as the repo name).
function Split-RepoArgument([object[]]$Arguments)
{
    $settings = Get-ClaudeSessionsSetting
    $repo = $settings.defaultRepo

    if ($Arguments.Count -gt 0 -and $Arguments[0] -notlike '-*')
    {
        $repo = $Arguments[0]
        $Arguments = @($Arguments | Select-Object -Skip 1)
    }

    [pscustomobject]@{ Path = Join-Path $settings.reposRoot $repo; ClaudeArguments = @($Arguments) }
}

function acd
{
    Set-Location -LiteralPath (Split-RepoArgument $args).Path -ErrorAction Stop
}

function cc
{
    $command = Split-RepoArgument $args
    $claudeArgs = $command.ClaudeArguments

    Set-Location -LiteralPath $command.Path -ErrorAction Stop
    claude @claudeArgs
}

function cca
{
    claude agents @args
}

function ccbg
{
    $command = Split-RepoArgument $args

    Start-ClaudeInBackground $command.Path $command.ClaudeArguments
}

# PowerShell strips the quotes from cch "two words", so an argument with a space in it is a phrase again. One that still has its
# quotes (cch '"two words"') is passed as typed.
function cch
{
    $query = ($args | ForEach-Object { if ("$_" -match '\s' -and "$_" -notmatch '"') { "`"$_`"" } else { "$_" } }) -join ' '
    $sessions = @(Search-ClaudeHistory $query)
    $script:ListedSessions = $sessions

    if ($sessions.Count -eq 0)
    {
        Write-Host "No sessions mention '$query'."
        return
    }

    for ($index = 0; $index -lt $sessions.Count; $index++)
        { $sessions[$index] | Add-Member -NotePropertyName Index -NotePropertyValue ($index + 1) -Force }

    $columns = @(
        @{ Name = ' '; Expression = { if ($_.pinned) { [char]0x2605 } } }
        'Index'
        @{ Name = 'title'; Expression = { $_.title.Substring(0, [Math]::Min(45, $_.title.Length)) } }
        @{ Name = 'repo'; Expression = { if ($_.cwd) { Split-Path $_.cwd -Leaf } } }
        @{ Name = 'active'; Expression = { Format-ClaudeAge $_.lastActive } }
        @{ Name = 'match'; Expression = { $_.snippet.Substring(0, [Math]::Min(90, $_.snippet.Length)) } }
    )

    $sessions | Format-Table -AutoSize -Property $columns
}

function cchandover
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$Target)

    $session = Resolve-ClaudeSession $Target
    $description = Get-ClaudeHandoverDescription $session

    if (-not $PSCmdlet.ShouldProcess("$($session.title): $description", "Hand over $($session.title)? $description", 'Hand over'))
        { return }

    Write-Host 'Writing handover...'
    $handover = Invoke-ClaudeHandover $session
    Write-Host "Handover saved to $($handover.handoverPath)`n$($handover.title) is starting in a new tab, pinned in place of $($session.title)."
}

function cchelp
{
    @'
acd     [repo]                  go to a repo under reposRoot (defaultRepo when omitted; both in settings.json)
cc      [repo] [claude flags]   start Claude in a repo, here in this tab      cc my-repo -n "feature x"
ccbg    [repo] [claude flags]   start Claude in the background                ccbg my-repo -n "feature x"
ccr     [repo] [search]         pick a past session in a repo to resume       ccr my-repo invoice
cca                             open agent view (background sessions)
ccl                             list sessions by last activity, numbered; the numbers stay valid in this tab until the next list
cch     <words>                 search all session history (your prompts, Claude's replies, titles); "quotes" for a phrase
cco     <title|#>               open a background session in this tab, or resume a stopped one here
ccstop  <title|#> [-Force]      stop a session after asking (-Force when it is busy)
cchandover <title|#>            after asking, stop an idle session, save its handover and continue in a new pinned session
ccpin   <title|#>               pin a session so ccrestore brings it back
ccunpin <title|#>               unpin a session
ccrename <title|#> [label]      label a session; no label goes back to Claude's title
ccrestore                       open every pinned session that is not running, each in its own tab
ccui                            open the sessions window
'@
}

function ccl
{
    $sessions = @(Get-ClaudeSession)
    $script:ListedSessions = $sessions

    if ($sessions.Count -eq 0)
    {
        Write-Host 'No running or pinned sessions.'
        return
    }

    $columns = @(
        @{ Name = ' '; Expression = { if ($_.pinned) { [char]0x2605 } } }
        'Index', 'title', 'branch', 'kind', 'status'
        @{ Name = 'repo'; Expression = { Split-Path $_.cwd -Leaf } }
        @{ Name = 'active'; Expression = { Format-ClaudeAge $_.lastActive } }
        @{ Name = 'context'; Expression = { Format-ClaudeTokens $_.contextTokens }; Alignment = 'Right' }
        @{ Name = 'MB'; Expression = { $_.memoryMB }; Alignment = 'Right' }
    )

    $sessions | Format-Table -AutoSize -Property $columns
}

function cco([string]$Target)
{
    $session = Resolve-ClaudeSession $Target

    if ($session.kind -eq 'interactive')
    {
        Write-Host "$($session.title) is open in its own terminal tab."
        return
    }

    if (-not $session.running)
    {
        Assert-ClaudeSessionStopped $session
        $nameArguments = if ($session.label) { @('--name', $session.label) }

        Set-Location -LiteralPath $session.cwd -ErrorAction Stop
        claude --resume $session.sessionId @nameArguments
        return
    }

    claude attach $session.id
}

function ccpin([string]$Target)
{
    Add-ClaudePin (Resolve-ClaudeSession $Target)
}

function ccr
{
    $command = Split-RepoArgument $args
    $claudeArgs = $command.ClaudeArguments

    Set-Location -LiteralPath $command.Path -ErrorAction Stop
    claude --resume @claudeArgs
}

function ccrename([string]$Target, [string]$Label)
{
    Set-ClaudeLabel (Resolve-ClaudeSession $Target).sessionId $Label
}

function ccrestore
{
    Restore-ClaudePinnedSession
}

function ccstop
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$Target, [switch]$Force)

    $session = Resolve-ClaudeSession $Target

    if ($PSCmdlet.ShouldProcess($session.title, 'Stop the session'))
        { Stop-ClaudeSession $session -Force:$Force }
}

function ccui
{
    Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-File', "`"$PSScriptRoot\ClaudeSessionsWindow.ps1`""
}

function ccunpin([string]$Target)
{
    Remove-ClaudePin (Resolve-ClaudeSession $Target).sessionId
}

Register-ArgumentCompleter -Native -CommandName acd, cc, ccbg, ccr -ScriptBlock {
    param($wordToComplete, $commandAst)

    $elementCount = $commandAst.CommandElements.Count

    if ($elementCount -gt 2 -or ($elementCount -eq 2 -and -not $wordToComplete))
        { return }

    Get-ChildItem (Get-ClaudeSessionsSetting).reposRoot -Directory -Filter "$wordToComplete*" | ForEach-Object Name
}

Register-ArgumentCompleter -CommandName cchandover, cco, ccpin, ccrename, ccstop, ccunpin -ParameterName Target -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete)

    $pattern = [WildcardPattern]::Escape($wordToComplete.Trim("'"))

    Get-ClaudeSession |
        Where-Object title -like "$pattern*" |
        ForEach-Object { if ($_.title -match "[\s']") { ConvertTo-PwshLiteral $_.title } else { $_.title } }
}
