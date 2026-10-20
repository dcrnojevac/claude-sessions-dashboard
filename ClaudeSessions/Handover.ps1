# Hand over: an idle session writes a handover document in one more turn, and a fresh session continues from it.

$ClaudeHandoversPath = Join-Path $ClaudeDataPath 'handovers'
$HandoverPrompt = "We are ending this session and continuing in a fresh one. Write a handover document for the next session, which will have none of this conversation's context. Cover: the goal and why it matters; decisions made and their reasons, including approaches rejected; the current state (what is done, verified, uncommitted or in progress, with file paths, branches and commands); open questions and blockers; constraints or preferences I stated; and the concrete next steps in order. Be specific and complete rather than brief; include anything you would want to know if you were starting over. Output only the document, in Markdown."
$HandoverStartPrompt = 'Read the handover at "{0}". Reply in a few lines with what you understand the current state and the next step to be, then stop and wait for my instructions. Do not start any work yet.'
$HandoverTimeout = [TimeSpan]::FromMinutes(15)

function Get-ClaudeHandoverDescription($Session)
{
    $stopStep = if ($Session.running) { 'Stops the session, then has it write' } else { 'Has the session write' }
    $contextNote = if ($Session.contextTokens) { " (one turn over its whole $(Format-ClaudeTokens $Session.contextTokens) context)" }
    $newTitle = Get-ClaudeHandoverTitle $Session.title

    "$stopStep a handover document$contextNote, then starts '$newTitle' in a new tab, pinned in its place. If no handover comes back, the old session stays pinned and resumable."
}

# "Title" continues as "Title (2)", "Title (2)" as "Title (3)".
function Get-ClaudeHandoverTitle([string]$Title)
{
    if ($Title -match '^(.*) \((\d+)\)$')
        { return "$($Matches[1]) ($([int]$Matches[2] + 1))" }

    "$Title (2)"
}

# Every step that can fail runs before the pins change, so a failure leaves the old session pinned and resumable. The session is
# stopped first because the handover turn resumes the same conversation.
function Invoke-ClaudeHandover($Session)
{
    if (-not $Session.cwd -or -not (Test-Path -LiteralPath $Session.cwd -PathType Container))
        { throw "The session's folder ($($Session.cwd)) does not exist." }

    $runningSession = Get-ClaudeRunningSession | Where-Object sessionId -eq $Session.sessionId

    if ($runningSession -and $runningSession.status -ne 'idle')
        { throw "$($Session.title) is $($runningSession.status); hand it over once it is idle." }

    if ($runningSession)
    {
        Stop-ClaudeSession $Session

        if (-not (Wait-ClaudeSession $Session.sessionId ([TimeSpan]::FromSeconds(20)) -Gone))
            { throw "$($Session.title) did not stop within 20 seconds." }
    }

    Assert-ClaudeSessionStopped $Session
    $handoverPath = Save-ClaudeHandover $Session.title (Request-ClaudeHandover $Session)

    $newSession = [pscustomobject]@{
        sessionId = [guid]::NewGuid().ToString()
        name = Get-ClaudeHandoverTitle $Session.title
        cwd = $Session.cwd
    }
    $startPrompt = $HandoverStartPrompt -f $handoverPath

    Open-ClaudeTab $newSession.name $newSession.cwd "claude --session-id $($newSession.sessionId) --name $(ConvertTo-PwshLiteral $newSession.name) $(ConvertTo-PwshLiteral $startPrompt)"

    # The pins wait for the new session to be listed under the id it was given, so they never point at a session that does not exist.
    if (-not (Wait-ClaudeSession $newSession.sessionId ([TimeSpan]::FromSeconds(60))))
        { throw "$($newSession.name) did not show up as session $($newSession.sessionId) within 60 seconds, so the old session stays pinned. The handover is in $handoverPath." }

    Add-ClaudePin $newSession -ReplacedSessionId $Session.sessionId

    [pscustomobject]@{ handoverPath = $handoverPath; title = $newSession.name; sessionId = $newSession.sessionId }
}

# The reply must come from the resumed session itself; anything else means Claude Code's resume changed.
function Request-ClaudeHandover($Session)
{
    $printArguments = @('-p', '--resume', $Session.sessionId, '--output-format', 'json', $HandoverPrompt)
    $printOutput = Invoke-ClaudeCommand $Session.cwd $printArguments $HandoverTimeout

    try
    {
        $reply = $printOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        throw "Claude's reply was not the expected JSON: $($printOutput.Substring(0, [Math]::Min(300, $printOutput.Length)))"
    }

    $handover = "$($reply.result)".Trim()

    if ($reply.type -ne 'result' -or $reply.session_id -ne $Session.sessionId)
        { throw "claude -p --resume answered as '$($reply.type)' for session $($reply.session_id), not the resumed one; Claude Code changed, so nothing else was done." }

    if ($reply.is_error -or -not $handover)
        { throw "Claude returned no handover ($($reply.subtype)): $handover" }

    $handover
}

# A second handover of the same title on the same day gets the time added rather than replacing the first.
function Save-ClaudeHandover([string]$Title, [string]$Handover)
{
    $fileTitle = $Title.Split([IO.Path]::GetInvalidFileNameChars()) -join '_'
    $handoverPath = Join-Path $ClaudeHandoversPath "$((Get-Date).ToString('yyyy-MM-dd')) $fileTitle.md"

    if (Test-Path -LiteralPath $handoverPath)
        { $handoverPath = Join-Path $ClaudeHandoversPath "$((Get-Date).ToString('yyyy-MM-dd HHmmss')) $fileTitle.md" }

    Save-ClaudeFile $handoverPath "$Handover`n"
    $handoverPath
}
