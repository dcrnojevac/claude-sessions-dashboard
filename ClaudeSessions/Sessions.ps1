# Claude Code's session list, the transcript details shown with it, and starting, resuming and stopping sessions. Claude Code's
# output and file formats are internal and change with updates, so whatever acts on them checks them first and stops on a mismatch.

$ClaudeCommandTimeout = [TimeSpan]::FromSeconds(20)
$RecentlyResumed = @{}

# An update renames the executable of a claude still running to claude.exe.old.<timestamp>.<pid>. Looked up by id, the process
# then goes by that name; listed with the others, it is still claude.
$ClaudeProcessNamePattern = '^claude(\.exe\.old\.[\d.]+)?$'

# A shell inside a Claude session has these set, and a claude started with them runs as that session's nested child: it replies
# normally but writes no transcript and never shows in claude agents. Your own CLAUDE_CODE_* settings are left alone.
$ParentSessionVariables = @(
    'CLAUDECODE'
    'CLAUDE_CODE_CHILD_SESSION'
    'CLAUDE_CODE_ENTRYPOINT'
    'CLAUDE_CODE_MESSAGING_SOCKET'
    'CLAUDE_CODE_MESSAGING_TOKEN'
    'CLAUDE_CODE_SESSION_ATTENDED'
    'CLAUDE_CODE_SESSION_ID'
    'CLAUDE_PID'
)

Add-Type -Namespace ClaudeSessions -Name TerminalWindow -UsingNamespace System.Text -MemberDefinition @'
delegate bool WindowVisitor(IntPtr window, IntPtr data);
[DllImport("user32.dll")] static extern bool EnumWindows(WindowVisitor visitor, IntPtr data);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder className, int size);
[DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
[DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
[DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);

// Windows are enumerated front to back, so the first match is the terminal window nearest the front.
public static void BringToFront()
{
    IntPtr frontTerminal = IntPtr.Zero;
    StringBuilder className = new StringBuilder(64);

    EnumWindows((window, data) =>
    {
        className.Length = 0;
        GetClassName(window, className, className.Capacity);

        if (className.ToString() != "CASCADIA_HOSTING_WINDOW_CLASS" || !IsWindowVisible(window) || IsIconic(window))
            return true;

        frontTerminal = window;
        return false;
    }, IntPtr.Zero);

    if (frontTerminal != IntPtr.Zero)
        SetForegroundWindow(frontTerminal);
}
'@

# Stopping, restoring and handing over act on these fields. Without them the tool would be guessing, and a missing sessionId, say,
# would make every pin look stopped and Restore open duplicates.
function Assert-ClaudeSessionEntry($Entry)
{
    $missingField = if ("$($Entry.sessionId)" -notmatch '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') { 'sessionId' }
        elseif (-not $Entry.cwd) { 'cwd' }
        elseif (-not $Entry.kind) { 'kind' }
        elseif (-not $Entry.status) { 'status' }
        elseif ($Entry.kind -eq 'interactive' -and ($Entry.pid -as [long]) -le 0) { 'pid' }
        elseif ($Entry.kind -eq 'interactive' -and ($Entry.startedAt -as [long]) -le 0) { 'startedAt' }
        elseif ($Entry.kind -ne 'interactive' -and -not $Entry.id) { 'id' }

    if ($missingField)
        { throw "claude agents --json changed: an entry has no usable '$missingField' ($(Get-ClaudeVersion)). ClaudeSessions does nothing until it is updated." }
}

# A second process on a running session's transcript corrupts the conversation. Claude's list misses a session whose process is
# still starting and a handover turn (claude -p), in this shell or any other, so a claude process naming the session counts too.
function Assert-ClaudeSessionStopped($Session)
{
    if (Get-ClaudeRunningSession | Where-Object sessionId -eq $Session.sessionId)
        { throw "$($Session.title) is already running." }

    if (Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$($Session.sessionId)*" })
        { throw "A claude process for $($Session.title) is already running: it is starting, or writing a handover." }
}

function ConvertTo-PwshLiteral([string]$Value)
{
    "'$($Value.Replace("'", "''"))'"
}

function Format-ClaudeAge($Time)
{
    if (-not $Time)
        { return }

    $age = (Get-Date) - $Time

    if ($age.TotalMinutes -lt 1)
        { return 'just now' }

    if ($age.TotalHours -lt 1)
        { return "$([Math]::Floor($age.TotalMinutes)) min ago" }

    if ($age.TotalDays -lt 1)
        { return "$([Math]::Floor($age.TotalHours)) h ago" }

    if ($age.TotalDays -lt 6)
        { return $Time.ToString('ddd HH:mm') }

    $Time.ToString('d MMM')
}

function Format-ClaudeTokens($Count)
{
    if ($Count)
        { "$([Math]::Round($Count / 1000))k" }
}

# A failed listing must not read as "nothing running", or Restore would open duplicates, so only a JSON list counts, empty or not.
function Get-ClaudeRunningSession
{
    $agentsJson = Invoke-ClaudeCommand '' @('agents', '--json') $ClaudeCommandTimeout

    try
    {
        $runningSessions = $agentsJson | ConvertFrom-Json -NoEnumerate -ErrorAction Stop
    }
    catch
    {
        $runningSessions = $null
    }

    if ($runningSessions -isnot [array])
        { throw "claude agents --json changed: it printed no list of sessions ($(Get-ClaudeVersion)). ClaudeSessions does nothing until it is updated." }

    foreach ($session in $runningSessions)
        { Assert-ClaudeSessionEntry $session }

    $runningSessions
}

# Running sessions, most recently active first, then pinned ones that are not running (kind 'stopped'). title is your label, else
# Claude's own title (from /rename or --name, else its AI title), else the session name. memoryMB is private memory: the part
# that counts against the commit limit and is not shared between processes, so totals add up.
function Get-ClaudeSession
{
    $labels = Get-ClaudeLabel
    $pins = @(Get-ClaudePin)
    $pinnedSessionIds = @($pins.sessionId)
    $runningSessions = @(Get-ClaudeRunningSession)
    $runningSessionIds = @($runningSessions.sessionId)

    $sessions = @(
        foreach ($session in $runningSessions)
        {
            $session |
                Add-Member -NotePropertyName pinned -NotePropertyValue ($session.sessionId -in $pinnedSessionIds) -PassThru |
                Add-Member -NotePropertyName running -NotePropertyValue $true -PassThru
        }

        foreach ($pin in $pins)
        {
            if ($pin.sessionId -notin $runningSessionIds)
            {
                [pscustomobject]@{
                    sessionId = $pin.sessionId
                    name = $pin.name
                    cwd = $pin.cwd
                    kind = 'stopped'
                    pinned = $true
                    running = $false
                }
            }
        }
    )

    foreach ($session in $sessions)
    {
        $transcript = Get-ClaudeTranscriptInfo $session.sessionId
        $label = $labels[$session.sessionId]
        $claudeTitle = $transcript.customTitle ?? $transcript.aiTitle
        $process = if ($session.running) { Get-Process -Id $session.pid -ErrorAction SilentlyContinue }
        $memoryMB = if ($process) { [int]($process.PrivateMemorySize64 / 1MB) }

        $session | Add-Member -NotePropertyMembers ([ordered]@{
            label = $label
            claudeTitle = $claudeTitle
            title = $label ?? $claudeTitle ?? $session.name
            branch = $transcript.branch
            lastActive = $transcript.lastActive
            lastPrompt = $transcript.lastPrompt
            contextTokens = $transcript.contextTokens
            memoryMB = $memoryMB
        })
    }

    $index = 0
    $order = @(@{ Expression = 'running'; Descending = $true }, @{ Expression = 'lastActive'; Descending = $true })

    $sessions | Sort-Object $order | ForEach-Object {
        $index++
        $_ | Add-Member -NotePropertyName Index -NotePropertyValue $index -PassThru
    }
}

# Claude Code appends the title (once per prompt), last prompt and git branch to the transcript as it goes, so the tail has the
# current ones without reading files that grow to tens of MB. One turn can write more than 256 KB (a big tool result), so a
# missing title or reply is looked for again in the last 4 MB. contextTokens is what Claude's last reply was sent.
function Get-ClaudeTranscriptInfo([string]$SessionId)
{
    $info = [pscustomobject]@{
        aiTitle = $null
        customTitle = $null
        lastPrompt = $null
        branch = $null
        contextTokens = $null
        lastActive = $null
    }
    $transcript = Get-Item "$HOME\.claude\projects\*\$SessionId.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $transcript)
        { return $info }

    foreach ($tailLength in 256KB, 4MB)
    {
        $tail = Read-ClaudeFileTail $transcript.FullName $tailLength
        $lines = $tail -split "`n"
        $branchMatch = [regex]::Matches($tail, '"gitBranch":"([^"]*)"') | Select-Object -Last 1
        $usage = (Select-LastTranscriptRecord $lines 'assistant').message.usage

        $info.aiTitle = (Select-LastTranscriptRecord $lines 'ai-title').aiTitle
        $info.customTitle = (Select-LastTranscriptRecord $lines 'custom-title').customTitle
        $info.lastPrompt = (Select-LastTranscriptRecord $lines 'last-prompt').lastPrompt

        if ($transcript.Length -le $tailLength -or (($info.customTitle -or $info.aiTitle) -and $usage))
            { break }
    }

    $info.lastActive = $transcript.LastWriteTime

    if ($branchMatch)
        { $info.branch = $branchMatch.Groups[1].Value }

    if ($usage)
        { $info.contextTokens = $usage.input_tokens + $usage.cache_read_input_tokens + $usage.cache_creation_input_tokens }

    $info
}

function Get-ClaudeVersion
{
    try
    {
        "Claude Code $((Invoke-ClaudeCommand '' @('--version') $ClaudeCommandTimeout).Trim())"
    }
    catch
    {
        'Claude Code version unknown'
    }
}

# Every claude call the tool waits on goes through here, so none can hang it: past the timeout the process and its children are
# killed. The output is read as UTF-8 whatever the console's code page, and stdin is closed so Claude does not wait for piped
# input. An empty Path keeps the current directory.
function Invoke-ClaudeCommand([string]$Path, [string[]]$ClaudeArguments, [TimeSpan]$Timeout)
{
    $startInfo = [System.Diagnostics.ProcessStartInfo]@{
        FileName = (Get-Command claude -CommandType Application | Select-Object -First 1).Source
        WorkingDirectory = $Path
        UseShellExecute = $false
        CreateNoWindow = $true
        RedirectStandardInput = $true
        RedirectStandardOutput = $true
        RedirectStandardError = $true
        StandardOutputEncoding = [Text.Encoding]::UTF8
        StandardErrorEncoding = [Text.Encoding]::UTF8
    }

    foreach ($argument in $ClaudeArguments)
        { $startInfo.ArgumentList.Add($argument) }

    foreach ($variable in $ParentSessionVariables)
        { $startInfo.Environment.Remove($variable) | Out-Null }

    $process = [System.Diagnostics.Process]::Start($startInfo)

    try
    {
        $process.StandardInput.Close()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $elapsed = [Diagnostics.Stopwatch]::StartNew()

        if (-not $process.WaitForExit($Timeout))
        {
            $process.Kill($true)
            throw "claude $($ClaudeArguments[0]) did not finish within $($Timeout.TotalSeconds) seconds and was stopped."
        }

        # A process claude started can inherit the output and hold it open after claude exits, so reading it has a deadline too:
        # what is left of the timeout, and at least 5 seconds.
        $outputDeadline = [TimeSpan]::FromTicks([Math]::Max(($Timeout - $elapsed.Elapsed).Ticks, [TimeSpan]::FromSeconds(5).Ticks))

        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outputTask, $errorTask), $outputDeadline))
            { throw "claude $($ClaudeArguments[0]) exited, but its output was still open $($outputDeadline.TotalSeconds) seconds later." }

        if ($process.ExitCode -ne 0)
            { throw "claude $($ClaudeArguments[0]) failed with exit code $($process.ExitCode): $($errorTask.Result.Trim()) $($outputTask.Result.Trim())" }

        $outputTask.Result
    }
    finally
    {
        $process.Dispose()
    }
}

# The command goes in as -EncodedCommand, so no quoting layer between wt.exe, the Windows command line and pwsh can mangle it;
# only the title and path pass through wt.exe, which splits its own command line on ';'. A killed claude leaves the terminal in
# mouse-tracking mode, where a shell left behind prints escape codes on every mouse move, so the tab ends with claude: exit 0
# makes Windows Terminal close it even after a kill. Windows Terminal hands the tab this process's environment, so the tab
# clears the parent-session variables itself.
function Open-ClaudeTab([string]$Title, [string]$Path, [string]$ClaudeCommand)
{
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container))
        { throw "The session's folder ($Path) does not exist." }

    $clearVariables = "Remove-Item $(($ParentSessionVariables | ForEach-Object { "env:$_" }) -join ', ') -ErrorAction SilentlyContinue"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$clearVariables`n$ClaudeCommand`nexit 0"))
    $tabTitle = $Title.Replace('"', "'").Replace(';', '\;')
    $tabPath = $Path.Replace(';', '\;')

    # A trailing backslash would escape the closing quote on the Windows command line.
    if ($tabPath.EndsWith('\'))
        { $tabPath += '.' }

    $arguments = "-w 0 new-tab --title `"$tabTitle`" -d `"$tabPath`" pwsh -NoLogo -EncodedCommand $encodedCommand"

    # Windows Terminal brings an open window forward by attaching to the input of the window in front and activating its own,
    # without SetForegroundWindow; when that is the sessions window, the taskbar can no longer bring it back. Already in front,
    # the terminal window has nothing to attach to.
    [ClaudeSessions.TerminalWindow]::BringToFront()
    Start-Process wt.exe -ArgumentList $arguments
}

# Shared for writing, since Claude keeps appending to the file.
function Read-ClaudeFileTail([string]$Path, [long]$Length)
{
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')

    try
    {
        $tailLength = [Math]::Min($stream.Length, $Length)
        $stream.Seek(-$tailLength, 'End') | Out-Null
        $buffer = [byte[]]::new($tailLength)
        $stream.ReadExactly($buffer)
    }
    finally
    {
        $stream.Dispose()
    }

    [Text.Encoding]::UTF8.GetString($buffer)
}

function Restore-ClaudePinnedSession
{
    $failures = @(
        foreach ($session in @(Get-ClaudeSession | Where-Object running -eq $false))
        {
            try
            {
                Resume-ClaudeInTab $session
            }
            catch
            {
                "$($session.title): $($_.Exception.Message)"
            }
        }
    )

    if ($failures)
        { throw "Not restored:`n$($failures -join "`n")" }
}

# The caller's list can be minutes old, so this checks again right before opening. For its first seconds a new tab has no claude
# process yet, so a session resumed here in the last 15 seconds counts as starting, unless it was stopped since. --name becomes
# Claude's own title for the session, so it is only passed to apply your label.
function Resume-ClaudeInTab($Session)
{
    Assert-ClaudeSessionStopped $Session
    $resumedAt = $script:RecentlyResumed[$Session.sessionId]

    if ($resumedAt -and (Get-Date) - $resumedAt -lt [TimeSpan]::FromSeconds(15))
        { throw "$($Session.title) was opened $([int]((Get-Date) - $resumedAt).TotalSeconds) seconds ago and is still starting." }

    $nameArgument = if ($Session.label) { " --name $(ConvertTo-PwshLiteral $Session.label)" }

    Open-ClaudeTab $Session.title $Session.cwd "claude --resume $($Session.sessionId)$nameArgument"
    $script:RecentlyResumed[$Session.sessionId] = Get-Date
}

# Scans back to the newest matching record that parses: the last line may be half-written, the first one cut by the tail read.
# Subagent replies (isSidechain) carry their own, smaller context, so they are skipped.
function Select-LastTranscriptRecord([string[]]$Lines, [string]$Type)
{
    for ($index = $Lines.Count - 1; $index -ge 0; $index--)
    {
        $line = $Lines[$index]

        if ($line -notlike "*`"type`":`"$Type`"*" -or $line -like '*"isSidechain":true*')
            { continue }

        try
        {
            return $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch
        {
            continue
        }
    }
}

function Start-ClaudeInBackground([string]$Path, [object[]]$ClaudeArguments)
{
    Push-Location -LiteralPath $Path -ErrorAction Stop

    try
    {
        claude --bg @ClaudeArguments
    }
    finally
    {
        Pop-Location
    }
}

# Works from Claude's list read right now, not the caller's, whose pid may belong to another process by then. Only an idle or
# busy session is stopped, and only when the pid is a claude process started when Claude says the session started, so a status or
# pid that came to mean something else stops nothing.
function Stop-ClaudeSession($Session, [switch]$Force)
{
    $runningSession = Get-ClaudeRunningSession | Where-Object sessionId -eq $Session.sessionId

    if (-not $runningSession)
        { throw "$($Session.title) is not running." }

    if ($runningSession.status -notin 'idle', 'busy')
        { throw "$($Session.title) has status '$($runningSession.status)', which this tool does not know; nothing was stopped." }

    if ($runningSession.status -eq 'busy' -and -not $Force)
        { throw "$($Session.title) is busy; ccstop -Force stops it mid-turn." }

    if ($runningSession.kind -eq 'interactive')
    {
        $process = Get-Process -Id $runningSession.pid -ErrorAction SilentlyContinue
        $startedAt = [DateTimeOffset]::FromUnixTimeMilliseconds($runningSession.startedAt).LocalDateTime

        if (-not $process -or $process.ProcessName -notmatch $ClaudeProcessNamePattern -or [Math]::Abs(($process.StartTime - $startedAt).TotalSeconds) -gt 10)
            { throw "pid $($runningSession.pid) is not the claude process Claude lists for $($Session.title); nothing was stopped." }

        Stop-Process -InputObject $process
    }
    else
    {
        Invoke-ClaudeCommand '' @('stop', $runningSession.id) $ClaudeCommandTimeout | Out-Null
    }

    $script:RecentlyResumed.Remove($Session.sessionId)
}

# True once Claude lists the session (with -Gone, once it no longer does), false if that has not happened within the timeout.
function Wait-ClaudeSession([string]$SessionId, [TimeSpan]$Timeout, [switch]$Gone)
{
    $deadline = (Get-Date) + $Timeout

    while ([bool](Get-ClaudeRunningSession | Where-Object sessionId -eq $SessionId) -eq [bool]$Gone)
    {
        if ((Get-Date) -gt $deadline)
            { return $false }

        Start-Sleep -Seconds 1
    }

    $true
}
