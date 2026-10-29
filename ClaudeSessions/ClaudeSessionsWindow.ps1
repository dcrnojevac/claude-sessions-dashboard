#Requires -Version 7.4

# The module next to this script, in each thread job too, so the window runs the code it ships with.
$ModulePath = Join-Path $PSScriptRoot 'ClaudeSessions.psm1'
Import-Module $ModulePath
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -Namespace ClaudeSessions -Name Native -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string className, string windowName);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
[StructLayout(LayoutKind.Sequential)] public struct Message { public IntPtr Window; public uint Id; public IntPtr WParam; public IntPtr LParam; public uint Time; public int X; public int Y; public uint Private; }
[DllImport("user32.dll")] static extern bool PeekMessage(out Message message, IntPtr window, uint firstId, uint lastId, uint remove);

// Removes queued keyboard, mouse and title-bar mouse input (the close button included) without handling it.
public static void DiscardQueuedInput()
{
    Message message;
    while (PeekMessage(out message, IntPtr.Zero, 0x0100, 0x0109, 1)) { }
    while (PeekMessage(out message, IntPtr.Zero, 0x0200, 0x020E, 1)) { }
    while (PeekMessage(out message, IntPtr.Zero, 0x00A0, 0x00AD, 1)) { }
}
'@

# Launching the window again brings the running one to the front, so the Start menu or a pinned icon always finds it.
$isFirstInstance = $false
$instanceMutex = [System.Threading.Mutex]::new($true, 'Local\ClaudeSessionsWindow', [ref]$isFirstInstance)

if (-not $isFirstInstance)
{
    $runningWindow = [ClaudeSessions.Native]::FindWindow([NullString]::Value, 'Claude Sessions')

    if ($runningWindow -ne [IntPtr]::Zero)
    {
        if ([ClaudeSessions.Native]::IsIconic($runningWindow))
            { [ClaudeSessions.Native]::ShowWindow($runningWindow, 9) | Out-Null }

        [ClaudeSessions.Native]::SetForegroundWindow($runningWindow) | Out-Null
    }

    return
}

# Its own taskbar identity: otherwise the button is shared with this process's hidden console window, and clicking it can pick
# that one, which cannot be shown.
[ClaudeSessions.Native]::SetCurrentProcessExplicitAppUserModelID('ClaudeSessions.Window') | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

try
{
    $settings = Get-ClaudeSessionsSetting
}
catch
{
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude Sessions', 'OK', 'Warning') | Out-Null
    return
}

# Light or dark as last switched with the window's button, otherwise as the Windows app mode is. Controls take the mode when
# they are created, so it is set here, once. .NET 8 (pwsh 7.4) has no dark mode, so there the window stays light.
$canSwitchColorMode = [bool][System.Windows.Forms.Application].GetMethod('SetColorMode')

if ($canSwitchColorMode)
{
    $colorMode = switch ($settings.colorMode) { 'Dark' { 'Dark' } 'Light' { 'Classic' } default { 'System' } }
    [System.Windows.Forms.Application]::SetColorMode($colorMode)
}

$isDarkMode = [bool][System.Windows.Forms.Application]::IsDarkModeEnabled

$PinnedMark = [string][char]0x2605
$UnpinnedMark = [string][char]0x2606
$LightModeMark = [string][char]0x2600
$DarkModeMark = [string][char]0x263E

# Header clicks sort on these values rather than the displayed text, which would put '17 min ago' before '2 min ago'.
$SortKeys = @{
    Title = { $_.title }
    Branch = { $_.branch }
    Repo = { Split-Path $_.cwd -Leaf }
    Kind = { $_.kind }
    Status = { $_.status }
    Active = { $_.lastActive }
    Context = { $_.contextTokens }
    Memory = { $_.memoryMB }
}

$NewestFirstColumns = @('Active', 'Context', 'Memory')
$LiveOnlyColumns = @('Pin', 'Reply', 'Kind', 'Status', 'Context', 'Memory')

$script:actionRunning = $false
$script:handoverJob = $null
$script:lastSessions = @()
$script:liveSessions = @()
$script:liveStatus = 'Refreshing...'
$script:searchMode = $false
$script:searchJob = $null
$script:lastQuery = ''
$script:sortColumn = 'Active'
$script:sortDescending = $true
$script:refreshGeneration = 0
$script:refreshJob = $null
$script:refreshJobGeneration = 0
$script:lastUpdatedAt = $null
$script:nextRefreshAt = [datetime]::MinValue
$script:shownSessionIds = $null
$script:reopenWindow = $false

# The tracker is optional: without TRACKER.md in its folder the window has no Tracker button and works as it always has.
$TrackerPath = Get-ClaudeTrackerPath $settings
$TrackerDocsUrl = 'https://github.com/dcrnojevac/claude-sessions-dashboard#optional-task-tracker'
$AfterStateColors = @{ waiting = [System.Drawing.Color]::DarkOrange; unknown = [System.Drawing.Color]::IndianRed; unblocked = [System.Drawing.Color]::MediumSeaGreen }
$AfterStateNotes = @{
    blocked = 'Waits on an open item.'
    unknown = 'Names an id that is neither in the tracker nor in the archive.'
    waiting = 'Waits on an outside event.'
    unblocked = 'Everything it waited on is archived, so it can start.'
}
$AfterStateLabels = @{ blocked = 'No'; unknown = 'Unknown id'; waiting = 'Waiting'; unblocked = 'Yes' }
$DueSoonDays = 3

# The archive sorts within each repo's group; the open items keep their order in the file, which is their priority.
$ArchiveSortKeys = @{
    Title = { $_.title ?? $_.raw }
    Since = { $_.latestStamp.date }
    Outcome = { $_.outcome }
}

$script:trackerMode = $false
$script:trackerIsSetUp = $false
$script:tracker = $null
$script:trackerReadAt = $null
$script:archiveSortColumn = 'Since'
$script:archiveSortDescending = $true
$script:trackerItemsById = @{}
$script:trackerOpenIds = [System.Collections.Generic.HashSet[string]]::new()
$script:trackerWaitingItems = @{}
$script:showArchive = $false
$script:trackerFilesStamp = $null
$script:nextTrackerCheckAt = [datetime]::MinValue
$script:trackerSplittersPlaced = $false

function Confirm-Action([string]$Message)
{
    $answer = [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Claude Sessions', 'YesNo', 'Question')

    $answer -eq 'Yes'
}

function Get-SelectedSession
{
    if ($grid.SelectedRows.Count -gt 0)
        { $grid.SelectedRows[0].Tag }
}

# Every action, its dialogs included, runs here on the UI thread, one at a time; a click, double-click or key that arrives anyway
# is ignored. Input made while the UI thread was busy waits in the queue, so it is discarded unread before the action counts as
# finished: handling it instead (DoEvents) could run a queued close in the middle of this cleanup. While a handover is being
# written only a new session can be started, since opening or restoring the old one would put a second process on its transcript.
function Invoke-SessionAction([scriptblock]$Action, [switch]$AllowDuringHandover)
{
    if ($script:actionRunning)
        { return }

    if ($script:handoverJob -and -not $AllowDuringHandover)
    {
        Show-Message 'Wait for the handover to finish.' 'Information'
        return
    }

    $script:actionRunning = $true
    $timer.Stop()
    Update-ActionState
    $form.UseWaitCursor = $true

    try
    {
        & $Action
    }
    catch
    {
        Show-Message $_.Exception.Message 'Warning'
    }
    finally
    {
        [ClaudeSessions.Native]::DiscardQueuedInput()
        $script:actionRunning = $false
        $form.UseWaitCursor = $false
        $script:refreshGeneration++
        $script:nextRefreshAt = [datetime]::MinValue

        if ($script:searchMode -and $script:lastQuery)
            { Start-HistorySearch $script:lastQuery }

        Update-ActionState
        $timer.Start()
    }
}

# Searching is a mode of its own: the live list and its refresh pause until Esc or the button, which then reads "Back to live list".
function Enter-SearchMode
{
    if ($script:trackerMode)
        { Exit-TrackerMode }

    if (-not $script:searchMode)
    {
        $script:searchMode = $true
        $script:refreshGeneration++
        Set-ColumnsForMode
        $statusLabel.Text = 'Type words from the conversation, then press Enter.'
    }

    $searchBox.Focus() | Out-Null
    $searchBox.SelectAll()
}

function Exit-SearchMode
{
    if ($script:searchJob)
    {
        Remove-Job $script:searchJob -Force
        $script:searchJob = $null
    }

    $script:searchMode = $false
    $script:nextRefreshAt = [datetime]::MinValue
    Set-ColumnsForMode
    $statusLabel.Text = $script:liveStatus
}

function Set-ColumnsForMode
{
    $modeHeader.Text = if ($script:searchMode) { 'History search' } else { 'Live sessions' }
    $searchHistoryButton.Text = if ($script:searchMode) { 'Back to live list' } else { 'Search history' }
    $searchPanel.Visible = $script:searchMode

    foreach ($column in $LiveOnlyColumns)
        { $grid.Columns[$column].Visible = -not $script:searchMode }

    $grid.Columns['Match'].Visible = $script:searchMode
    $script:shownSessionIds = $null
    $script:lastSessions = @()
    $grid.Rows.Clear()

    # The last live list comes back at once instead of an empty table until the refresh lands.
    if (-not $script:searchMode)
        { Show-Session $script:liveSessions }

    Update-ActionState
}

# The first search builds the history cache, which can take a while, so it runs on a thread job like the refresh.
function Start-HistorySearch([string]$Query)
{
    if (-not $Query.Trim())
        { return }

    if ($script:searchJob)
        { Remove-Job $script:searchJob -Force }

    $script:lastQuery = $Query.Trim()
    $script:searchJob = Start-ThreadJob { param($modulePath, $query) Import-Module $modulePath; Search-ClaudeHistory $query } -ArgumentList $ModulePath, $script:lastQuery
    $statusLabel.Text = "Searching for '$($script:lastQuery)'..."
}

# Once a search result is open, the live list is where it shows up; a failed open keeps the results in view.
function Open-SelectedSession
{
    $session = Get-SelectedSession

    if (-not $session)
        { return }

    Invoke-SessionAction {
        if ($session.kind -eq 'interactive')
        {
            Show-Message "$($session.title) is open in its own terminal tab." 'Information'
            return
        }

        if ($session.running)
            { Open-ClaudeTab $session.title $session.cwd "claude attach $($session.id)" }
        else
            { Resume-ClaudeInTab $session }

        if ($script:searchMode)
            { Exit-SearchMode }
    }
}

# Returns $null when cancelled, otherwise the new label; an empty label goes back to Claude's title.
function Read-SessionLabel($Session)
{
    $dialog = [System.Windows.Forms.Form]@{
        Text = 'Rename session'
        FormBorderStyle = 'FixedDialog'
        StartPosition = 'CenterParent'
        MinimizeBox = $false
        MaximizeBox = $false
        ShowInTaskbar = $false
        AutoSize = $true
        AutoSizeMode = 'GrowAndShrink'
        Padding = [System.Windows.Forms.Padding]::new(12)
        Font = $form.Font
    }

    $layout = [System.Windows.Forms.FlowLayoutPanel]@{ FlowDirection = 'TopDown'; AutoSize = $true }
    $hintText = "Leave empty to use Claude's title: $($Session.claudeTitle ?? $Session.name)`nClaude itself shows the new name from the next resume, or right away after /rename in the session."
    $hint = [System.Windows.Forms.Label]@{ AutoSize = $true; Text = $hintText }
    $labelBox = [System.Windows.Forms.TextBox]@{ Width = 460; Text = $Session.title }
    $buttons = [System.Windows.Forms.FlowLayoutPanel]@{ FlowDirection = 'RightToLeft'; AutoSize = $true; Width = 460 }
    $cancelButton = [System.Windows.Forms.Button]@{ Text = 'Cancel'; DialogResult = 'Cancel'; AutoSize = $true }
    $okButton = [System.Windows.Forms.Button]@{ Text = 'Rename'; DialogResult = 'OK'; AutoSize = $true }

    $buttons.Controls.AddRange(@($cancelButton, $okButton))
    $layout.Controls.AddRange(@($hint, $labelBox, $buttons))
    $dialog.Controls.Add($layout)
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    if ($dialog.ShowDialog($form) -ne 'OK')
        { return $null }

    $label = $labelBox.Text.Trim()

    if ($label -eq $Session.claudeTitle)
        { return '' }

    $label
}

function Show-Message([string]$Message, [string]$Icon)
{
    [System.Windows.Forms.MessageBox]::Show($form, $Message, 'Claude Sessions', 'OK', $Icon) | Out-Null
}

# The list stays as it was, so the status says how old it is.
function Show-RefreshProblem([string]$Problem)
{
    $shownData = if ($script:lastUpdatedAt) { "showing data from $($script:lastUpdatedAt.ToString('HH:mm:ss'))" } else { 'no data yet' }

    $statusLabel.Text = "Refresh $Problem · $shownData"
}

function Set-SessionRow($Row, $Session)
{
    $pinMark = if ($Session.pinned) { $PinnedMark } else { $UnpinnedMark }
    $status = @($Session.status, $Session.state) | Where-Object { $_ }
    $memory = if ($Session.memoryMB) { "$($Session.memoryMB) MB" }
    $lastPrompt = if ($Session.lastPrompt) { "Last prompt: $($Session.lastPrompt.Substring(0, [Math]::Min(300, $Session.lastPrompt.Length)))`n`n" }

    $values = [ordered]@{
        Pin = $pinMark
        Title = $Session.title
        Reply = $Session.replyOpening
        Branch = $Session.branch
        Repo = Split-Path $Session.cwd -Leaf
        Kind = $Session.kind
        Status = $status -join ', '
        Active = Format-ClaudeAge $Session.lastActive
        Context = Format-ClaudeTokens $Session.contextTokens
        Memory = $memory
        Match = $Session.snippet
    }

    foreach ($column in $values.Keys)
        { $Row.Cells[$column].Value = $values[$column] }

    $Row.Tag = $Session
    $Row.Cells['Match'].Tag = if ($Session.snippet) { @(Split-ClaudeSearchMatchText $Session.snippet $script:lastQuery) }
    $Row.Cells['Title'].ToolTipText = "$lastPrompt$($Session.name)  $($Session.sessionId)"
    $Row.DefaultCellStyle.ForeColor = if ($Session.running) { [System.Drawing.Color]::Empty } else { [System.Drawing.SystemColors]::GrayText }
    $Row.Cells['Status'].Style.ForeColor = if ($Session.status -eq 'busy') { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::Empty }
}

# Rows are rebuilt only when the sessions or their order change; otherwise the cells update in place, so the selection and the
# scroll position stay put. In the live list running sessions always sort above stopped ones.
function Show-Session([object[]]$Sessions)
{
    $script:lastSessions = $Sessions

    $order = @(
        if (-not $script:searchMode)
            { @{ Expression = 'running'; Descending = $true } }

        @{ Expression = $SortKeys[$script:sortColumn]; Descending = $script:sortDescending }
    )

    $sortedSessions = @($Sessions | Sort-Object $order)
    $sessionIds = @($sortedSessions.sessionId) -join ';'

    if ($sessionIds -ne $script:shownSessionIds)
    {
        $script:shownSessionIds = $sessionIds
        $selectedSessionId = (Get-SelectedSession).sessionId
        $grid.Rows.Clear()

        foreach ($session in $sortedSessions)
        {
            $row = $grid.Rows[$grid.Rows.Add()]
            Set-SessionRow $row $session

            if ($session.sessionId -eq $selectedSessionId)
                { $grid.CurrentCell = $row.Cells['Title'] }
        }
    }
    else
    {
        for ($index = 0; $index -lt $sortedSessions.Count; $index++)
            { Set-SessionRow $grid.Rows[$index] $sortedSessions[$index] }
    }

    foreach ($column in $grid.Columns)
        { $column.HeaderCell.SortGlyphDirection = 'None' }

    $grid.Columns[$script:sortColumn].HeaderCell.SortGlyphDirection = if ($script:sortDescending) { 'Descending' } else { 'Ascending' }
    Update-ActionState
}

# The tracker is a mode of its own like search: the live list and its refresh pause until Esc or the button. Its archive is a
# level below, which Esc or Back to tracker leaves.
function Enter-TrackerMode
{
    if ($script:searchMode)
        { Exit-SearchMode }

    $script:trackerMode = $true
    $script:refreshGeneration++
    Show-Tracker

    # A splitter can only be placed once its container has its real size.
    if (-not $script:trackerSplittersPlaced -and $trackerSplit.Visible)
    {
        $trackerSplit.SplitterDistance = [int]($trackerSplit.Width * 0.55)
        $trackerSidePanel.SplitterDistance = [int]($trackerSidePanel.Height * 0.55)
        $script:trackerSplittersPlaced = $true
    }

    $trackerGrid.Focus() | Out-Null
}

function Exit-TrackerMode
{
    $script:trackerMode = $false
    $script:showArchive = $false
    $trackerFilterBox.Clear()
    $script:nextRefreshAt = [datetime]::MinValue
    Set-TrackerVisibility
    $statusLabel.Text = $script:liveStatus
}

function Get-SelectedTrackerItem
{
    if ($trackerGrid.SelectedRows.Count -gt 0 -and $trackerGrid.SelectedRows[0].Tag -isnot [string])
        { $trackerGrid.SelectedRows[0].Tag }
}

# Changes to the index, the archive or a details file, checked by name, size and write time.
function Get-TrackerFilesStamp
{
    $files = Get-ChildItem -LiteralPath $TrackerPath, (Join-Path $TrackerPath 'items') -File -ErrorAction SilentlyContinue

    @($files | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
}

function Format-TrackerAfter($Item)
{
    $links = foreach ($link in $Item.after)
    {
        switch ($link.state)
        {
            'open' { $script:trackerItemsById[$link.id].title }
            'archived' { "$($script:trackerItemsById[$link.id].title) (done)" }
            'missing' { "[$($link.id)] not found" }
            default { $link.event }
        }
    }

    # Titles have commas of their own.
    $links -join '; '
}

# Picks the item in the list, switching between the open items and the archive when it is in the other one.
function Select-TrackerItem([string]$Id)
{
    if (-not $script:trackerItemsById.Contains($Id))
        { return }

    $isArchived = -not $script:trackerOpenIds.Contains($Id)

    if (-not (Test-TrackerFilter $script:trackerItemsById[$Id]))
        { $trackerFilterBox.Clear() }

    if ($isArchived -ne $script:showArchive)
        { Show-TrackerArchive $isArchived }

    foreach ($row in $trackerGrid.Rows)
    {
        if ($row.Tag -isnot [string] -and $row.Tag.id -eq $Id)
        {
            $trackerGrid.CurrentCell = $row.Cells['Title']
            break
        }
    }
}

function Show-TrackerArchive([bool]$ShowArchive)
{
    $script:showArchive = $ShowArchive
    Show-Tracker
}

function Open-SelectedTrackerDetails
{
    $item = Get-SelectedTrackerItem

    if ($item.detailsPath)
        { Invoke-SessionAction -AllowDuringHandover { Invoke-Item -LiteralPath $item.detailsPath } }
}

function Set-TrackerRow($Row, $Item)
{
    $Row.Tag = $Item

    if (-not $Item.id)
    {
        $Row.Cells['Title'].Value = $Item.raw
        $Row.Cells['Title'].ToolTipText = 'This line is not in the tracker format, so it is shown as written.'
        $Row.DefaultCellStyle.ForeColor = [System.Drawing.SystemColors]::GrayText
        return
    }

    $stampDate = $Item.latestStamp.date
    $since = if (-not $stampDate) { $Item.latestStamp.text }
        elseif ($script:showArchive) { $stampDate.ToString('yyyy-MM-dd') }
        else { "$($stampDate.ToString('yyyy-MM-dd')), $(Format-ClaudeDaysSince $stampDate)" }

    $values = [ordered]@{
        Title = $Item.title
        Repo = $Item.repo
        Since = $since
        After = if ($Item.afterState) { $AfterStateLabels[$Item.afterState] }
        Due = @($Item.due, (Format-ClaudeDaysUntil $Item.dueDate) | Where-Object { $_ }) -join ', '
        Outcome = $Item.outcome
    }

    foreach ($column in $values.Keys)
        { $Row.Cells[$column].Value = $values[$column] }

    $Row.Cells['Title'].ToolTipText = $Item.raw
    $Row.Cells['Since'].ToolTipText = $Item.latestStamp.text

    if ($Item.afterState)
    {
        $Row.Cells['After'].ToolTipText = "$($AfterStateNotes[$Item.afterState])`n$(Format-TrackerAfter $Item)"
        $Row.Cells['After'].Style.ForeColor = $AfterStateColors[$Item.afterState] ?? [System.Drawing.Color]::Empty
    }

    if ($Item.dueDate)
    {
        $daysLeft = ($Item.dueDate.Date - (Get-Date).Date).TotalDays
        $Row.Cells['Due'].Style.ForeColor = if ($daysLeft -le 0) { [System.Drawing.Color]::IndianRed }
            elseif ($daysLeft -le $DueSoonDays) { [System.Drawing.Color]::DarkOrange }
            else { [System.Drawing.Color]::Empty }
    }
}

# Read on entering the tracker and again whenever one of its files changes.
function Show-Tracker
{
    $script:trackerFilesStamp = Get-TrackerFilesStamp

    try
    {
        $tracker = Get-ClaudeTracker $TrackerPath
    }
    catch
    {
        $statusLabel.Text = "Could not read the tracker: $($_.Exception.Message)"
        return
    }

    $script:trackerIsSetUp = $tracker.isSetUp
    $script:tracker = $tracker
    Set-TrackerVisibility

    if (-not $tracker.isSetUp)
    {
        $statusLabel.Text = ''
        return
    }

    # The Dependencies pane follows the selection, so it looks items up here instead of in the rows: by id (an open item before an
    # archived one of the same id), and by the id each open item waits on.
    $script:trackerItemsById = @{}
    $script:trackerOpenIds = [System.Collections.Generic.HashSet[string]]::new()
    $script:trackerWaitingItems = @{}

    foreach ($item in @($tracker.items) + @($tracker.archivedItems) | Where-Object id)
        { $script:trackerItemsById[$item.id] ??= $item }

    foreach ($item in $tracker.items | Where-Object id)
    {
        $script:trackerOpenIds.Add($item.id) | Out-Null

        foreach ($link in $item.after | Where-Object id)
        {
            $script:trackerWaitingItems[$link.id] ??= [System.Collections.Generic.List[object]]::new()
            $script:trackerWaitingItems[$link.id].Add($item)
        }
    }

    $script:trackerReadAt = Get-Date
    Show-TrackerItems
}

# Every word of the filter is somewhere in the item's line, in any case.
function Test-TrackerFilter($Item)
{
    foreach ($word in $trackerFilterBox.Text -split '\s+' | Where-Object { $_ })
    {
        if (-not $Item.raw.Contains($word, [StringComparison]::OrdinalIgnoreCase))
            { return $false }
    }

    $true
}

# The open items stay in file order under a heading row per section. The archive has a heading row per repo, the items without one
# last, and inside each the newest first unless a header click sorts them otherwise.
function Show-TrackerItems
{
    $tracker = $script:tracker
    $isArchive = $script:showArchive

    foreach ($column in 'Repo', 'After', 'Due')
        { $trackerGrid.Columns[$column].Visible = -not $isArchive }

    $trackerGrid.Columns['Outcome'].Visible = $isArchive

    foreach ($column in $trackerGrid.Columns)
    {
        $isSorted = $isArchive -and $column.Name -eq $script:archiveSortColumn
        $column.SortMode = if ($isArchive -and $ArchiveSortKeys.Contains($column.Name)) { 'Programmatic' } else { 'NotSortable' }
        $column.HeaderCell.SortGlyphDirection = if (-not $isSorted) { 'None' } elseif ($script:archiveSortDescending) { 'Descending' } else { 'Ascending' }
    }

    $shownItems = @(if ($isArchive) { $tracker.archivedItems } else { $tracker.items }) | Where-Object { Test-TrackerFilter $_ }

    if ($isArchive)
    {
        $shownItems = @($shownItems)
        [array]::Reverse($shownItems)

        $order = @(
            @{ Expression = { -not $_.repo } }
            @{ Expression = { $_.repo } }
            @{ Expression = $ArchiveSortKeys[$script:archiveSortColumn]; Descending = $script:archiveSortDescending }
        )
        $shownItems = $shownItems | Sort-Object -Stable $order
    }

    $selectedId = (Get-SelectedTrackerItem).id
    $selectedRow = $null
    $headingRow = $null
    $trackerGrid.Rows.Clear()

    # A column sized to its cells measures them all again for each row added, so sizing waits until the rows are in.
    foreach ($column in $contentSizedTrackerColumns)
        { $column.AutoSizeMode = 'None' }

    foreach ($item in $shownItems)
    {
        $group = if ($isArchive) { $item.repo ?? 'No repo' } else { $item.section ?? 'No section' }

        if (-not $headingRow -or $group -ne $headingGroup)
        {
            $headingGroup = $group
            $headingRow = $trackerGrid.Rows[$trackerGrid.Rows.Add()]
            $headingRow.DefaultCellStyle.BackColor = [System.Drawing.SystemColors]::Control
            $groupCount = 0
        }

        $row = $trackerGrid.Rows[$trackerGrid.Rows.Add()]
        Set-TrackerRow $row $item
        $groupCount++
        $headingRow.Tag = "$group  ($groupCount)"

        if (-not $selectedRow -or ($item.id -and $item.id -eq $selectedId))
            { $selectedRow = $row }
    }

    foreach ($column in $contentSizedTrackerColumns)
        { $column.AutoSizeMode = 'AllCells' }

    if ($selectedRow)
        { $trackerGrid.CurrentCell = $selectedRow.Cells['Title'] }

    Show-TrackerItemDetails

    $openCount = @($tracker.items | Where-Object id).Count
    $rawCount = @($tracker.items + $tracker.archivedItems | Where-Object { -not $_.id }).Count
    $rawNote = if ($rawCount) { " · $rawCount lines not in the tracker format" }
    $filterNote = if ($trackerFilterBox.Text.Trim()) { " · $(@($shownItems).Count) match" }
    $statusLabel.Text = "$openCount open · $($tracker.archivedItems.Count) archived$rawNote$filterNote · read $($script:trackerReadAt.ToString('HH:mm:ss'))"
}

function Show-TrackerItemDetails
{
    $item = Get-SelectedTrackerItem
    $details = $null

    if ($item.detailsPath)
    {
        try
        {
            $details = Read-ClaudeTrackerDetails $item.detailsPath
        }
        catch
        {
            $details = "Could not read $($item.detailsPath): $($_.Exception.Message)"
        }
    }
    elseif ($item.detailsLink)
    {
        $details = "$($item.detailsLink) is linked but does not exist."
    }

    $daysInState = Format-ClaudeDaysSince $item.latestStamp.date
    $latest = if ($daysInState -and -not $script:showArchive) { "$($item.latestStamp.text), $daysInState" } else { $item.latestStamp.text }

    $trackerTitleLabel.Text = if ($item.id) { $item.title } elseif ($item) { 'A line not in the tracker format' } else { 'No item selected' }
    $trackerSubtitleLabel.Text = @($item.id, $item.section, $latest | Where-Object { $_ }) -join '  ·  '
    Set-TrackerDetailsText $(if ($item) { "$($item.raw)`n`n$details".TrimEnd() } else { '' })
    Set-TrackerTitleHeight
    Show-TrackerTree $item
    Update-ActionState
}

# The box counts a line break as one character, so the bold runs are placed in text with \n breaks only.
function Set-TrackerDetailsText([string]$Text)
{
    $runs = @(Split-ClaudeTrackerBoldText ($Text -replace '\r\n?', "`n") $script:trackerItemsById.Keys)
    $trackerDetailsBox.Text = $runs.text -join ''
    $runStart = 0

    foreach ($run in $runs)
    {
        if ($run.isBold)
        {
            $trackerDetailsBox.Select($runStart, $run.text.Length)
            $trackerDetailsBox.SelectionFont = $trackerDetailsBoldFont
        }

        $runStart += $run.text.Length
    }

    $trackerDetailsBox.Select(0, 0)
}

# The title wraps, so its label is as tall as the wrapped text at the pane's current width.
function Set-TrackerTitleHeight
{
    $textSize = [System.Drawing.Size]::new([Math]::Max(1, $trackerTitleLabel.ClientSize.Width), [int]::MaxValue)
    $textHeight = [System.Windows.Forms.TextRenderer]::MeasureText($trackerTitleLabel.Text, $trackerTitleLabel.Font, $textSize, 'WordBreak').Height

    $trackerTitleLabel.Height = $textHeight + $trackerTitleLabel.Padding.Vertical
}

# The selected item's dependencies both ways: what it waits on, and what those wait on in turn, then the items waiting on it, and
# what waits on those. A link that comes back to an item already on its path stops there.
function Show-TrackerTree($Item)
{
    $trackerTree.BeginUpdate()
    $trackerTree.Nodes.Clear()

    if ($Item.id)
    {
        $waitsOnNode = [System.Windows.Forms.TreeNode]@{ Text = 'Waits on'; ForeColor = [System.Drawing.SystemColors]::GrayText }
        $waitingLabel = if ($script:trackerOpenIds.Contains($Item.id)) { 'Waiting on it' } else { 'Unblocked by it' }
        $waitingNode = [System.Windows.Forms.TreeNode]@{ Text = $waitingLabel; ForeColor = [System.Drawing.SystemColors]::GrayText }

        Add-TrackerWaitsOnNodes $waitsOnNode $Item @($Item.id)
        Add-TrackerWaitingNodes $waitingNode $Item.id @($Item.id)

        foreach ($groupNode in @($waitsOnNode, $waitingNode) | Where-Object { $_.Nodes.Count -gt 0 })
            { $trackerTree.Nodes.Add($groupNode) | Out-Null }
    }

    if ($trackerTree.Nodes.Count -eq 0)
    {
        $emptyText = if ($Item.id) { 'This item has no dependencies.' } else { 'Select an item to see its dependencies.' }
        $trackerTree.Nodes.Add([System.Windows.Forms.TreeNode]@{ Text = $emptyText; ForeColor = [System.Drawing.SystemColors]::GrayText }) | Out-Null
    }

    $trackerTree.ExpandAll()
    $trackerTree.EndUpdate()
}

function Add-TrackerWaitsOnNodes($Node, $Item, [string[]]$PathIds)
{
    foreach ($link in $Item.after)
    {
        $linkedItem = if ($link.id) { $script:trackerItemsById[$link.id] }

        $child = switch ($link.state)
        {
            { $_ -in 'open', 'archived' } { New-TrackerNode $linkedItem }
            'missing' { [System.Windows.Forms.TreeNode]@{ Text = "[$($link.id)] not in the tracker or the archive"; ForeColor = $AfterStateColors.unknown } }
            default { [System.Windows.Forms.TreeNode]@{ Text = "Outside event: $($link.event)"; ForeColor = $AfterStateColors.waiting } }
        }

        $Node.Nodes.Add($child) | Out-Null

        if ($link.state -ne 'open')
            { continue }

        if ($link.id -in $PathIds)
            { $child.Text += '  (loops back)' }
        else
            { Add-TrackerWaitsOnNodes $child $linkedItem ($PathIds + $link.id) }
    }
}

function Add-TrackerWaitingNodes($Node, [string]$Id, [string[]]$PathIds)
{
    foreach ($waitingItem in $script:trackerWaitingItems[$Id])
    {
        $child = New-TrackerNode $waitingItem
        $Node.Nodes.Add($child) | Out-Null

        if ($waitingItem.id -in $PathIds)
            { $child.Text += '  (loops back)' }
        else
            { Add-TrackerWaitingNodes $child $waitingItem.id ($PathIds + $waitingItem.id) }
    }
}

# An archived item is green: it is done, so what waits on it can start.
function New-TrackerNode($Item)
{
    $isArchived = -not $script:trackerOpenIds.Contains($Item.id)
    $section = if ($isArchived) { 'done' } else { $Item.section }
    $color = if ($isArchived) { $AfterStateColors.unblocked } else { [System.Drawing.Color]::Empty }

    [System.Windows.Forms.TreeNode]@{ Text = "[$($Item.id)] $($Item.title)  ·  $section"; Tag = $Item; ToolTipText = $Item.raw; ForeColor = $color }
}

# Navigation is in the top bar: the live list's Search history and Tracker, the tracker's Archive and Back to live list, and in
# the archive only Back to tracker. The bottom bar holds the actions on the selected row.
function Set-TrackerVisibility
{
    $isTracker = $script:trackerMode
    $isArchive = $isTracker -and $script:showArchive
    $hasItems = $isTracker -and $script:trackerIsSetUp

    $modeHeader.Text = if ($isArchive) { 'Tracker archive' } elseif ($isTracker) { 'Tracker' } else { 'Live sessions' }
    $trackerButton.Text = if ($isTracker) { 'Back to live list' } else { 'Tracker' }
    $grid.Visible = -not $isTracker
    $trackerSplit.Visible = $hasItems
    $trackerMissingLabel.Visible = $isTracker -and -not $script:trackerIsSetUp
    $searchHistoryButton.Visible = -not $isArchive
    $archiveButton.Visible = $hasItems -and -not $isArchive
    $backToTrackerButton.Visible = $isArchive
    $openDetailsButton.Visible = $hasItems

    if ($isTracker)
        { $trackerButton.Visible = -not $isArchive }

    foreach ($control in @($openButton, $renameButton, $pinButton, $stopButton, $handoverButton, $restoreButton))
        { $control.Visible = -not $isTracker }

    Update-ActionState
}

# Search results are only for finding a session and opening it; everything else acts on the live list.
function Update-ActionState
{
    $session = Get-SelectedSession
    $isIdle = -not $script:actionRunning -and -not $script:handoverJob
    $isLive = $isIdle -and -not $script:searchMode
    $pinText = if ($session.pinned) { 'Unpin' } else { 'Pin' }

    foreach ($control in @($openButton, $openMenuItem))
        { $control.Enabled = $isIdle -and $session }

    foreach ($control in @($pinButton, $pinMenuItem, $renameButton, $renameMenuItem))
        { $control.Enabled = $isLive -and $session }

    foreach ($control in @($stopButton, $stopMenuItem))
        { $control.Enabled = $isLive -and $session.running }

    foreach ($control in @($handoverButton, $handoverMenuItem))
        { $control.Enabled = $isLive -and $session -and (-not $session.running -or $session.status -eq 'idle') }

    $restoreButton.Enabled = $isLive
    $startButton.Enabled = -not $script:actionRunning
    $colorModeButton.Enabled = $isIdle
    $trackerButton.Enabled = -not $script:actionRunning
    $openDetailsButton.Enabled = -not $script:actionRunning -and (Get-SelectedTrackerItem).detailsPath

    foreach ($control in @($pinButton, $pinMenuItem))
        { $control.Text = $pinText }
}

function New-Button([string]$Text, [scriptblock]$OnClick)
{
    $button = [System.Windows.Forms.Button]@{ Text = $Text; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(6, 2, 6, 2) }
    $button.Add_Click($OnClick)

    $button
}

# The session list and the tracker list. Dark mode leaves the column headers drawn in the light theme, so there they are plain,
# without the current column's highlight, and the selected row's text, black on blue by default, stays white.
function New-Grid
{
    $newGrid = [System.Windows.Forms.DataGridView]@{
        Dock = 'Fill'
        ReadOnly = $true
        AllowUserToAddRows = $false
        AllowUserToDeleteRows = $false
        AllowUserToResizeRows = $false
        SelectionMode = 'FullRowSelect'
        MultiSelect = $false
        RowHeadersVisible = $false
        AutoSizeColumnsMode = 'Fill'
        BorderStyle = 'None'
        CellBorderStyle = 'SingleHorizontal'
        BackgroundColor = [System.Drawing.SystemColors]::Window
        RowTemplate = [System.Windows.Forms.DataGridViewRow]@{ Height = 30 }
    }

    $newGrid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $newGrid.ColumnHeadersHeight = 34

    if ($isDarkMode)
    {
        $newGrid.DefaultCellStyle.SelectionForeColor = $newGrid.DefaultCellStyle.ForeColor
        $newGrid.EnableHeadersVisualStyles = $false
        $newGrid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $newGrid.ColumnHeadersDefaultCellStyle.BackColor
        $newGrid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $newGrid.ColumnHeadersDefaultCellStyle.ForeColor
    }

    $newGrid
}

function New-MenuItem([string]$Text, [scriptblock]$OnClick)
{
    $menuItem = [System.Windows.Forms.ToolStripMenuItem]::new($Text)
    $menuItem.Add_Click($OnClick)

    $menuItem
}

$openAction = { Open-SelectedSession }

$stopAction = {
    $session = Get-SelectedSession

    Invoke-SessionAction {
        $busy = $session.status -eq 'busy'
        $question = if ($busy) { "$($session.title) is busy. Stop it mid-turn?" } else { "Stop $($session.title)?" }

        if (Confirm-Action $question)
            { Stop-ClaudeSession $session -Force:$busy }
    }
}

# The handover turn can take minutes on a big session, so it runs on a thread job and the timer reports the outcome.
$handoverAction = {
    $session = Get-SelectedSession

    Invoke-SessionAction {
        if (-not (Confirm-Action "Hand over $($session.title)?`n`n$(Get-ClaudeHandoverDescription $session)"))
            { return }

        $script:handoverJob = Start-ThreadJob { param($modulePath, $session) Import-Module $modulePath; Invoke-ClaudeHandover $session } -ArgumentList $ModulePath, $session
        $handoverLabel.Text = "Writing handover for $($session.title)..."
        $handoverLabel.Visible = $true
    }
}

$pinAction = {
    $session = Get-SelectedSession

    Invoke-SessionAction {
        if ($session.pinned)
            { Remove-ClaudePin $session.sessionId }
        else
            { Add-ClaudePin $session }
    }
}

$renameAction = {
    $session = Get-SelectedSession

    Invoke-SessionAction {
        $label = Read-SessionLabel $session

        if ($null -ne $label)
            { Set-ClaudeLabel $session.sessionId $label }
    }
}

$restoreAction = { Invoke-SessionAction { Restore-ClaudePinnedSession } }

$startAction = {
    Invoke-SessionAction -AllowDuringHandover {
        $repo = $repoBox.SelectedItem
        $name = $nameBox.Text.Trim()
        $tabTitle = if ($name) { $name } else { Split-Path $repo -Leaf }
        $claudeCommand = if ($name) { "claude --name $(ConvertTo-PwshLiteral $name)" } else { 'claude' }

        Open-ClaudeTab $tabTitle (Join-Path $settings.reposRoot $repo) $claudeCommand
        $nameBox.Clear()
    }
}

# The mode cannot change under open controls, so switching saves the other one and the window reopens in it once it has closed.
# The form closes only after the action has finished with it.
$colorModeAction = {
    Invoke-SessionAction {
        Set-ClaudeSessionsSetting colorMode ($isDarkMode ? 'Light' : 'Dark')
        $script:reopenWindow = $true
    }

    if ($script:reopenWindow)
        { $form.Close() }
}

# The Start menu shortcut uses the same icon file, so the taskbar pin and the window look alike.
$form = [System.Windows.Forms.Form]@{
    Text = 'Claude Sessions'
    Icon = [System.Drawing.Icon]::new((Join-Path $PSScriptRoot 'ClaudeSessions.ico'))
    Size = [System.Drawing.Size]::new(1700, 800)
    StartPosition = 'CenterScreen'
    Font = [System.Drawing.Font]::new('Segoe UI', 10)
}

# Starting a session and the navigation flow from the left; the color mode switch sits on its own at the right.
$topBar = [System.Windows.Forms.TableLayoutPanel]@{ Dock = 'Top'; AutoSize = $true; ColumnCount = 2; RowCount = 1; Padding = [System.Windows.Forms.Padding]::new(8) }
$topBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100)) | Out-Null
$topBar.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize')) | Out-Null
$topPanel = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Fill'; AutoSize = $true; Margin = [System.Windows.Forms.Padding]::Empty }
$labelMargin = [System.Windows.Forms.Padding]::new(3, 7, 3, 0)
$repoBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle = 'DropDownList'; Width = 250 }
$repoBox.Items.AddRange([object[]]@(Get-ClaudeRepo $settings.reposRoot))
$widestRepo = ($repoBox.Items | ForEach-Object { [System.Windows.Forms.TextRenderer]::MeasureText($_, $form.Font).Width } | Measure-Object -Maximum).Maximum
$repoBox.DropDownWidth = [Math]::Max($repoBox.Width, $widestRepo + 30)

# A default that names no single repo leaves nothing selected.
try
{
    $repoBox.SelectedItem = [IO.Path]::GetRelativePath($settings.reposRoot, (Resolve-ClaudeRepo $settings.reposRoot $settings.defaultRepo))
}
catch
{
}
$nameBox = [System.Windows.Forms.TextBox]@{ Width = 260 }
$nameBox.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $startAction } })

$searchHistoryButton = New-Button 'Search history' { if ($script:searchMode) { Exit-SearchMode } else { Enter-SearchMode } }
$trackerButton = New-Button 'Tracker' { if ($script:trackerMode) { Exit-TrackerMode } else { Enter-TrackerMode } }
$trackerButton.Visible = Test-ClaudeTracker $TrackerPath
$archiveButton = New-Button 'Archive' { Show-TrackerArchive $true }
$archiveButton.Visible = $false
$backToTrackerButton = New-Button 'Back to tracker' { Show-TrackerArchive $false }
$backToTrackerButton.Visible = $false

# Its own panel, so the gap before it stays whichever of its buttons are hidden.
$navigationPanel = [System.Windows.Forms.FlowLayoutPanel]@{ AutoSize = $true; WrapContents = $false; Margin = [System.Windows.Forms.Padding]::new(37, 0, 0, 0) }
$navigationPanel.Controls.AddRange(@($searchHistoryButton, $trackerButton, $archiveButton, $backToTrackerButton))

$colorModeName = $isDarkMode ? 'Light mode' : 'Dark mode'
$colorModeButton = New-Button ($isDarkMode ? $LightModeMark : $DarkModeMark) $colorModeAction
$colorModeButton.Font = [System.Drawing.Font]::new('Segoe UI Symbol', 11)
$colorModeButton.AccessibleName = $colorModeName
$colorModeButton.Anchor = 'Right'
$colorModeButton.Visible = $canSwitchColorMode
([System.Windows.Forms.ToolTip]::new()).SetToolTip($colorModeButton, $colorModeName)

$topPanel.Controls.AddRange(@(
    [System.Windows.Forms.Label]@{ Text = 'New session in'; AutoSize = $true; Margin = $labelMargin }
    $repoBox
    [System.Windows.Forms.Label]@{ Text = 'named'; AutoSize = $true; Margin = $labelMargin }
    $nameBox
    ($startButton = New-Button 'Start' $startAction)
    $navigationPanel
))

$topBar.Controls.Add($topPanel, 0, 0)
$topBar.Controls.Add($colorModeButton, 1, 0)

$searchPanel = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Top'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(8, 0, 8, 8); Visible = $false }
$searchBox = [System.Windows.Forms.TextBox]@{ Width = 460 }
$searchBox.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Start-HistorySearch $searchBox.Text } })
$searchButton = New-Button 'Search' { Start-HistorySearch $searchBox.Text }

$searchPanel.Controls.AddRange(@(
    [System.Windows.Forms.Label]@{ Text = 'Search history for'; AutoSize = $true; Margin = $labelMargin }
    $searchBox
    $searchButton
))

$modeHeader = [System.Windows.Forms.Label]@{
    Text = 'Live sessions'
    Dock = 'Top'
    Height = 34
    Padding = [System.Windows.Forms.Padding]::new(10, 6, 0, 0)
    Font = [System.Drawing.Font]::new('Segoe UI Semibold', 12)
}

$grid = New-Grid
$pinColumn = [System.Windows.Forms.DataGridViewButtonColumn]@{ Name = 'Pin'; HeaderText = ''; FlatStyle = 'Standard'; AutoSizeMode = 'None'; Width = 44 }
$pinColumn.DefaultCellStyle.Font = [System.Drawing.Font]::new('Segoe UI Symbol', 12)
$grid.Columns.Add($pinColumn) | Out-Null

foreach ($column in @(('Title', 24), ('Reply', 30), ('Branch', 18), ('Repo', 9), ('Kind', 9), ('Status', 10), ('Active', 11), ('Context', 7), ('Memory', 8)))
{
    $grid.Columns.Add($column[0], $column[0]) | Out-Null
    $grid.Columns[$column[0]].FillWeight = $column[1]
    $grid.Columns[$column[0]].SortMode = 'Programmatic'
}

$grid.Columns['Reply'].HeaderText = 'Last reply'
$grid.Columns['Reply'].SortMode = 'NotSortable'

foreach ($column in @('Context', 'Memory'))
    { $grid.Columns[$column].DefaultCellStyle.Alignment = 'MiddleRight' }

$grid.Columns.Add('Match', 'Match') | Out-Null
$grid.Columns['Match'].FillWeight = 60
$grid.Columns['Match'].SortMode = 'NotSortable'
$grid.Columns['Match'].Visible = $false

# A cell has one font, so the Match text is drawn here, run by run, the search terms bold. The run that reaches the cell's edge
# ends in an ellipsis like the other cells' text.
$grid.Add_CellPainting({
    if ($_.RowIndex -lt 0 -or $_.ColumnIndex -ne $grid.Columns['Match'].Index -or -not $grid.Rows[$_.RowIndex].Cells['Match'].Tag)
        { return }

    $_.Paint($_.CellBounds, [System.Windows.Forms.DataGridViewPaintParts]::All -bxor [System.Windows.Forms.DataGridViewPaintParts]::ContentForeground)
    $script:searchMatchBoldFont ??= [System.Drawing.Font]::new('Segoe UI Semibold', $_.CellStyle.Font.Size, $_.CellStyle.Font.Unit)
    $isSelected = $_.State.HasFlag([System.Windows.Forms.DataGridViewElementStates]::Selected)
    $foreColor = if ($isSelected) { $_.CellStyle.SelectionForeColor } else { $_.CellStyle.ForeColor }
    $flags = [System.Windows.Forms.TextFormatFlags]'NoPadding, NoPrefix, SingleLine, VerticalCenter'
    $textBounds = [System.Drawing.Rectangle]::new($_.CellBounds.X + 2, $_.CellBounds.Y, $_.CellBounds.Width - 4, $_.CellBounds.Height - 1)
    $x = $textBounds.X

    foreach ($run in $grid.Rows[$_.RowIndex].Cells['Match'].Tag)
    {
        $font = if ($run.isBold) { $script:searchMatchBoldFont } else { $_.CellStyle.Font }
        $runWidth = [System.Windows.Forms.TextRenderer]::MeasureText($_.Graphics, $run.text, $font, [System.Drawing.Size]::Empty, $flags).Width
        $isLastShown = $x + $runWidth -gt $textBounds.Right
        $runBounds = [System.Drawing.Rectangle]::new($x, $textBounds.Y, ($isLastShown ? $textBounds.Right - $x : $runWidth), $textBounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $run.text, $font, $runBounds, $foreColor, ($isLastShown ? $flags -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis : $flags))
        $x += $runWidth

        if ($isLastShown)
            { break }
    }

    $_.Handled = $true
})

# Dark mode leaves the star buttons drawn in the light theme, and draws the sort arrow in a grey that hardly shows. So each star
# is drawn as a button like the window's own, lighter under the mouse, and a solid arrow in the header's text color goes over the
# sort arrow.
if ($isDarkMode)
{
    $script:hotPinRow = -1

    $grid.Add_CellMouseEnter({
        if ($_.RowIndex -ge 0 -and $_.ColumnIndex -eq $pinColumn.Index)
        {
            $script:hotPinRow = $_.RowIndex
            $grid.Cursor = 'Hand'
            $grid.InvalidateCell($_.ColumnIndex, $_.RowIndex)
        }
    })

    $grid.Add_CellMouseLeave({
        if ($_.RowIndex -ge 0 -and $_.ColumnIndex -eq $pinColumn.Index)
        {
            $script:hotPinRow = -1
            $grid.Cursor = 'Default'
            $grid.InvalidateCell($_.ColumnIndex, $_.RowIndex)
        }
    })

    $grid.Add_CellPainting({
        if ($_.RowIndex -ge 0 -and $_.ColumnIndex -eq $pinColumn.Index)
        {
            $_.Paint($_.CellBounds, 'Background, SelectionBackground, Border')
            $fillShade, $borderShade = if ($_.RowIndex -eq $script:hotPinRow) { 84, 210 } else { 62, 155 }
            $button = [System.Drawing.Rectangle]::new($_.CellBounds.X + 7, $_.CellBounds.Y + 4, $_.CellBounds.Width - 15, $_.CellBounds.Height - 10)
            $fill = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($fillShade, $fillShade, $fillShade))
            $border = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb($borderShade, $borderShade, $borderShade))
            $corner = [System.Drawing.Size]::new(8, 8)
            $smoothing = $_.Graphics.SmoothingMode
            $_.Graphics.SmoothingMode = 'AntiAlias'
            $_.Graphics.FillRoundedRectangle($fill, $button, $corner)
            $_.Graphics.DrawRoundedRectangle($border, $button, $corner)
            $_.Graphics.SmoothingMode = $smoothing
            $fill.Dispose()
            $border.Dispose()
            [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $_.FormattedValue, $_.CellStyle.Font, $button, $_.CellStyle.ForeColor, 'HorizontalCenter, VerticalCenter')
            $_.Handled = $true
            return
        }

        $direction = if ($_.RowIndex -eq -1 -and $_.ColumnIndex -ge 0) { $grid.Columns[$_.ColumnIndex].HeaderCell.SortGlyphDirection }

        if ($direction -notin 'Ascending', 'Descending')
            { return }

        $_.Paint($_.CellBounds, 'All')
        $scale = $_.Graphics.DpiX / 96
        $x = $_.CellBounds.Right - 10.5 * $scale
        $y = $_.CellBounds.Top + $_.CellBounds.Height / 2
        $tip = if ($direction -eq 'Descending') { 4 * $scale } else { -4 * $scale }
        $brush = [System.Drawing.SolidBrush]::new($_.CellStyle.ForeColor)
        $arrow = [System.Drawing.PointF[]]@(
            [System.Drawing.PointF]::new($x - 4.5 * $scale, $y - $tip)
            [System.Drawing.PointF]::new($x + 4.5 * $scale, $y - $tip)
            [System.Drawing.PointF]::new($x, $y + $tip)
        )
        $_.Graphics.FillPolygon($brush, $arrow)
        $brush.Dispose()
        $_.Handled = $true
    })
}

$openMenuItem = New-MenuItem 'Open' $openAction
$renameMenuItem = New-MenuItem 'Rename' $renameAction
$pinMenuItem = New-MenuItem 'Pin' $pinAction
$stopMenuItem = New-MenuItem 'Stop' $stopAction
$handoverMenuItem = New-MenuItem 'Hand over' $handoverAction
$grid.ContextMenuStrip = [System.Windows.Forms.ContextMenuStrip]::new()
$grid.ContextMenuStrip.Items.AddRange(@($openMenuItem, $renameMenuItem, $pinMenuItem, $stopMenuItem, $handoverMenuItem))

$grid.Add_SelectionChanged({ Update-ActionState })

$grid.Add_ColumnHeaderMouseClick({
    $columnName = $grid.Columns[$_.ColumnIndex].Name

    if (-not $SortKeys.Contains($columnName))
        { return }

    if ($columnName -eq $script:sortColumn)
    {
        $script:sortDescending = -not $script:sortDescending
    }
    else
    {
        $script:sortColumn = $columnName
        $script:sortDescending = $columnName -in $NewestFirstColumns
    }

    Show-Session $script:lastSessions
})
$grid.Add_CellDoubleClick({ if ($_.RowIndex -ge 0 -and $_.ColumnIndex -ne $pinColumn.Index) { & $openAction } })
$grid.Add_CellContentClick({ if ($_.RowIndex -ge 0 -and $_.ColumnIndex -eq $pinColumn.Index) { & $pinAction } })
$grid.Add_CellMouseDown({ if ($_.RowIndex -ge 0 -and $_.Button -eq 'Right') { $grid.CurrentCell = $grid.Rows[$_.RowIndex].Cells['Title'] } })

$grid.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter')
    {
        $_.SuppressKeyPress = $true
        & $openAction
    }

    if ($_.KeyCode -eq 'F2' -and -not $script:searchMode)
        { & $renameAction }
})

$trackerGrid = New-Grid

foreach ($column in @(('Title', 70, 'Title'), ('Repo', 0, 'Repo'), ('Since', 0, 'Since'), ('After', 0, 'Can start'), ('Due', 0, 'Due'), ('Outcome', 50, 'Outcome')))
{
    $trackerGrid.Columns.Add($column[0], $column[2]) | Out-Null
    $trackerGrid.Columns[$column[0]].SortMode = 'NotSortable'

    if ($column[1])
        { $trackerGrid.Columns[$column[0]].FillWeight = $column[1] }
    else
        { $trackerGrid.Columns[$column[0]].AutoSizeMode = 'AllCells' }
}

$contentSizedTrackerColumns = @($trackerGrid.Columns | Where-Object AutoSizeMode -eq 'AllCells')

$trackerGrid.Add_ColumnHeaderMouseClick({
    $columnName = $trackerGrid.Columns[$_.ColumnIndex].Name

    if (-not $script:showArchive -or -not $ArchiveSortKeys.Contains($columnName))
        { return }

    if ($columnName -eq $script:archiveSortColumn)
    {
        $script:archiveSortDescending = -not $script:archiveSortDescending
    }
    else
    {
        $script:archiveSortColumn = $columnName
        $script:archiveSortDescending = $columnName -eq 'Since'
    }

    Show-TrackerItems
})

$sectionFont = [System.Drawing.Font]::new('Segoe UI Semibold', 10)

# A section's heading row spans the whole width: its cells paint only their background, and the name goes over them afterwards.
$trackerGrid.Add_CellPainting({
    if ($_.RowIndex -ge 0 -and $trackerGrid.Rows[$_.RowIndex].Tag -is [string])
    {
        $_.Paint($_.CellBounds, 'Background, Border')
        $_.Handled = $true
    }
})

$trackerGrid.Add_RowPostPaint({
    $heading = $trackerGrid.Rows[$_.RowIndex].Tag

    if ($heading -is [string])
    {
        $textBounds = [System.Drawing.Rectangle]::new($_.RowBounds.X + 6, $_.RowBounds.Y, $_.RowBounds.Width - 6, $_.RowBounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $heading, $sectionFont, $textBounds, [System.Drawing.SystemColors]::ControlText, 'Left, VerticalCenter')
    }
})

$trackerGrid.Add_SelectionChanged({ Show-TrackerItemDetails })
$trackerGrid.Add_CellDoubleClick({ if ($_.RowIndex -ge 0) { Open-SelectedTrackerDetails } })

$trackerGrid.Add_KeyDown({
    if ($_.KeyCode -eq 'Enter')
    {
        $_.SuppressKeyPress = $true
        Open-SelectedTrackerDetails
    }
})

$trackerTree = [System.Windows.Forms.TreeView]@{ Dock = 'Fill'; BorderStyle = 'None'; HideSelection = $false; ShowNodeToolTips = $true; DrawMode = 'OwnerDrawText' }

# The details pane's bold Consolas, so an id looks the same in both; bold Segoe UI would stand out far more. The tree draws 10pt
# Consolas at the size the details box needs 10.5pt for, since the two round points to pixels differently.
$trackerTreeIdFont = [System.Drawing.Font]::new('Consolas', 10, [System.Drawing.FontStyle]::Bold)

# A node can only be bold as a whole, so each node's text is drawn here, its leading [id] bold. Drawing one node means drawing
# them all, so the group nodes match the selection colors too.
$trackerTree.Add_DrawNode({
    if ($_.Bounds.IsEmpty)
        { return }

    $idText = [regex]::Match($_.Node.Text, '^\[[^\]]+\]').Value
    $restText = $_.Node.Text.Substring($idText.Length)
    $isSelected = $_.State.HasFlag([System.Windows.Forms.TreeNodeStates]::Selected)
    $isHighlighted = $isSelected -and $trackerTree.Focused
    $flags = [System.Windows.Forms.TextFormatFlags]'NoPadding, NoPrefix, SingleLine, VerticalCenter'
    $idWidth = if ($idText) { [System.Windows.Forms.TextRenderer]::MeasureText($_.Graphics, $idText, $trackerTreeIdFont, [System.Drawing.Size]::Empty, $flags).Width } else { 0 }
    $restWidth = [System.Windows.Forms.TextRenderer]::MeasureText($_.Graphics, $restText, $trackerTree.Font, [System.Drawing.Size]::Empty, $flags).Width

    $backColor = if ($isHighlighted) { [System.Drawing.SystemColors]::Highlight } elseif ($isSelected) { [System.Drawing.SystemColors]::Control } else { $trackerTree.BackColor }
    $foreColor = if ($isHighlighted) { [System.Drawing.SystemColors]::HighlightText } elseif (-not $_.Node.ForeColor.IsEmpty) { $_.Node.ForeColor } else { $trackerTree.ForeColor }
    $background = [System.Drawing.Rectangle]::new($_.Bounds.X, $_.Bounds.Y, [Math]::Max($_.Bounds.Width, $idWidth + $restWidth + 4), $_.Bounds.Height)
    $idBounds = [System.Drawing.Rectangle]::new($background.X + 2, $background.Y, $idWidth, $background.Height)
    $restBounds = [System.Drawing.Rectangle]::new($idBounds.Right, $background.Y, $restWidth, $background.Height)

    $brush = [System.Drawing.SolidBrush]::new($backColor)
    $_.Graphics.FillRectangle($brush, $background)
    $brush.Dispose()
    [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $idText, $trackerTreeIdFont, $idBounds, $foreColor, $flags)
    [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $restText, $trackerTree.Font, $restBounds, $foreColor, $flags)
})

# Double-clicking an item goes to it, and the tree then shows that item's dependencies. The tree is rebuilt only after the
# double-click has been handled, so the control never finishes it on a node that is gone.
$trackerTree.Add_NodeMouseDoubleClick({
    $script:trackerItemToSelect = $_.Node.Tag.id

    if ($script:trackerItemToSelect)
        { $trackerTree.BeginInvoke([Action]{ Select-TrackerItem $script:trackerItemToSelect }) | Out-Null }
})

# At 10pt the box draws Consolas a pixel step smaller, where its bold is hardly heavier than the regular text.
$trackerDetailsBox = [System.Windows.Forms.RichTextBox]@{
    Dock = 'Fill'
    ReadOnly = $true
    ScrollBars = 'Vertical'
    BorderStyle = 'None'
    DetectUrls = $false
    BackColor = [System.Drawing.SystemColors]::Window
    Font = [System.Drawing.Font]::new('Consolas', 10.5)
}
$trackerDetailsBoldFont = [System.Drawing.Font]::new($trackerDetailsBox.Font, [System.Drawing.FontStyle]::Bold)

$trackerTitleLabel = [System.Windows.Forms.Label]@{ Dock = 'Top'; Padding = [System.Windows.Forms.Padding]::new(0, 6, 0, 2); Font = [System.Drawing.Font]::new('Segoe UI Semibold', 12) }
$trackerSubtitleLabel = [System.Windows.Forms.Label]@{ Dock = 'Top'; Height = 26; ForeColor = [System.Drawing.SystemColors]::GrayText }
$trackerSidePanel = [System.Windows.Forms.SplitContainer]@{ Dock = 'Fill'; Orientation = 'Horizontal' }
$trackerSidePanel.Panel1.Controls.AddRange(@($trackerDetailsBox, $trackerSubtitleLabel, $trackerTitleLabel))
$trackerSidePanel.Panel1.Add_Resize({ Set-TrackerTitleHeight })
$trackerSidePanel.Panel2.Controls.AddRange(@(
    $trackerTree
    [System.Windows.Forms.Label]@{ Text = 'Dependencies'; Dock = 'Top'; Height = 30; Padding = [System.Windows.Forms.Padding]::new(0, 6, 0, 0); Font = $sectionFont }
))

$trackerFilterPanel = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Top'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(0, 0, 0, 6) }
$trackerFilterBox = [System.Windows.Forms.TextBox]@{ Width = 460; PlaceholderText = 'Words anywhere in the line' }
$trackerFilterBox.Add_TextChanged({ if ($script:trackerMode -and $script:trackerIsSetUp) { Show-TrackerItems } })
$trackerFilterPanel.Controls.AddRange(@(
    [System.Windows.Forms.Label]@{ Text = 'Filter'; AutoSize = $true; Margin = $labelMargin }
    $trackerFilterBox
))

$trackerSplit = [System.Windows.Forms.SplitContainer]@{ Dock = 'Fill'; Visible = $false }
$trackerSplit.Panel1.Controls.AddRange(@($trackerGrid, $trackerFilterPanel))
$trackerSplit.Panel2.Controls.Add($trackerSidePanel)
$trackerSplit.Panel2.Padding = [System.Windows.Forms.Padding]::new(8, 0, 8, 0)

# Shown only when the tracker goes away while it is open; without one the window has no Tracker button.
$trackerDocsText = 'Optional: task tracker in the README'
$trackerMissingText = "There is no tracker in $TrackerPath. The tracker is optional; to set one up, see $trackerDocsText."
$trackerMissingLabel = [System.Windows.Forms.LinkLabel]@{ Dock = 'Fill'; Visible = $false; Padding = [System.Windows.Forms.Padding]::new(12, 8, 12, 0); Text = $trackerMissingText }
$trackerMissingLabel.LinkArea = [System.Windows.Forms.LinkArea]::new($trackerMissingText.IndexOf($trackerDocsText), $trackerDocsText.Length)
$trackerMissingLabel.Add_LinkClicked({ Start-Process $TrackerDocsUrl })

# Dark mode keeps the light theme's dark blue link.
if ($isDarkMode)
    { $trackerMissingLabel.LinkColor = $trackerMissingLabel.ActiveLinkColor = [System.Drawing.Color]::LightSkyBlue }

$bottomPanel = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Bottom'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(8) }
$openDetailsButton = New-Button 'Open details' { Open-SelectedTrackerDetails }
$openDetailsButton.Visible = $false
$openButton = New-Button 'Open' $openAction
$renameButton = New-Button 'Rename' $renameAction
$pinButton = New-Button 'Pin' $pinAction
$stopButton = New-Button 'Stop' $stopAction
$handoverButton = New-Button 'Hand over' $handoverAction
$restoreButton = New-Button 'Restore pinned' $restoreAction
$restoreButton.Margin = [System.Windows.Forms.Padding]::new(40, 3, 3, 3)
$statusLabel = [System.Windows.Forms.Label]@{ AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(20, 9, 3, 0); ForeColor = [System.Drawing.SystemColors]::GrayText }
$handoverLabel = [System.Windows.Forms.Label]@{ AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(20, 9, 3, 0); ForeColor = [System.Drawing.Color]::DarkOrange; Visible = $false }
$bottomPanel.Controls.AddRange(@(
    $openButton, $renameButton, $pinButton, $stopButton, $handoverButton, $restoreButton, $openDetailsButton, $statusLabel, $handoverLabel
))

$form.Controls.AddRange(@($grid, $trackerSplit, $trackerMissingLabel, $searchPanel, $modeHeader, $topBar, $bottomPanel))

foreach ($fillControl in @($grid, $trackerSplit, $trackerMissingLabel))
    { $fillControl.BringToFront() }

$form.KeyPreview = $true

$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'F')
    {
        $_.SuppressKeyPress = $true

        if ($script:trackerMode -and $script:trackerIsSetUp)
        {
            $trackerFilterBox.Focus() | Out-Null
            $trackerFilterBox.SelectAll()
        }
        else
        {
            Enter-SearchMode
        }
    }

    if ($_.KeyCode -eq 'Escape' -and $script:searchMode)
    {
        $_.SuppressKeyPress = $true
        Exit-SearchMode
    }

    # Esc clears the filter first, and only then leaves the archive or the tracker.
    if ($_.KeyCode -eq 'Escape' -and $script:trackerMode)
    {
        $_.SuppressKeyPress = $true

        if ($trackerFilterBox.Text)
            { $trackerFilterBox.Clear() }
        elseif ($script:showArchive)
            { Show-TrackerArchive $false }
        else
            { Exit-TrackerMode }
    }
})

# Buttons beside input fields are as tall as the fields, so each bar lines up. The fields only have their real height once the
# window's font reaches them.
$form.Add_Load({
    $fieldHeight = $repoBox.Height

    foreach ($field in @($nameBox, $searchBox))
    {
        $field.AutoSize = $false
        $field.Height = $fieldHeight
    }

    foreach ($button in @($startButton, $searchHistoryButton, $trackerButton, $archiveButton, $backToTrackerButton, $searchButton))
        { $button.MinimumSize = $button.MaximumSize = [System.Drawing.Size]::new(0, $fieldHeight) }

    # Dark mode repaints a button as soon as its text changes, before the bar is laid out again, so a button whose text switches
    # keeps the width of its longer text; otherwise the new text shows wrapped in the old width for a moment.
    foreach ($button in @($searchHistoryButton, $trackerButton))
    {
        $text = $button.Text
        $button.Text = 'Back to live list'
        $switchedWidth = $button.PreferredSize.Width
        $button.Text = $text
        $button.MinimumSize = [System.Drawing.Size]::new([Math]::Max($switchedWidth, $button.PreferredSize.Width), $fieldHeight)
    }

    $colorModeButton.AutoSize = $false
    $colorModeButton.Size = [System.Drawing.Size]::new($fieldHeight + 8, $fieldHeight)
})

# Each listing starts a claude.exe (about 0.2 s of CPU and 180 MB for a moment), so it runs on a thread job to keep the window
# responsive, every 10 seconds, paused while minimized.
$timer = [System.Windows.Forms.Timer]@{ Interval = 500 }

$timer.Add_Tick({
    if ($script:handoverJob -and $script:handoverJob.State -in 'Completed', 'Failed', 'Stopped')
    {
        $handover = Receive-Job $script:handoverJob -ErrorVariable handoverErrors -ErrorAction SilentlyContinue | Select-Object -Last 1
        Remove-Job $script:handoverJob
        $script:handoverJob = $null
        $handoverLabel.Visible = $false
        $script:refreshGeneration++
        $script:nextRefreshAt = [datetime]::MinValue
        Update-ActionState

        if ($handoverErrors)
            { Show-Message "Handover failed: $($handoverErrors[0])" 'Warning' }
        else
            { Show-Message "Handover saved to $($handover.handoverPath)`n`n$($handover.title) is starting in a new tab, pinned in place of the old session." 'Information' }
    }

    if ($script:searchJob)
    {
        if ($script:searchJob.State -notin 'Completed', 'Failed', 'Stopped')
            { return }

        $results = @(Receive-Job $script:searchJob -ErrorVariable searchErrors -ErrorAction SilentlyContinue)
        Remove-Job $script:searchJob
        $script:searchJob = $null

        if ($searchErrors)
        {
            $statusLabel.Text = "Search failed: $($searchErrors[0])"
            return
        }

        Show-Session $results
        $statusLabel.Text = "$($results.Count) sessions mention '$($script:lastQuery)'"
        return
    }

    if ($script:searchMode)
        { return }

    if ($script:trackerMode)
    {
        if ((Get-Date) -ge $script:nextTrackerCheckAt)
        {
            $script:nextTrackerCheckAt = (Get-Date).AddSeconds(2)

            if ((Get-TrackerFilesStamp) -ne $script:trackerFilesStamp)
                { Show-Tracker }
        }

        return
    }

    if ($script:refreshJob)
    {
        if ($script:refreshJob.State -notin 'Completed', 'Failed', 'Stopped')
            { return }

        $sessions = @(Receive-Job $script:refreshJob -ErrorVariable refreshErrors -ErrorAction SilentlyContinue)
        $isCurrent = $script:refreshJobGeneration -eq $script:refreshGeneration
        Remove-Job $script:refreshJob
        $script:refreshJob = $null

        if (-not $isCurrent)
            { return }

        $script:nextRefreshAt = (Get-Date).AddSeconds(10)

        if ($refreshErrors)
        {
            Show-RefreshProblem "failed: $($refreshErrors[0])"
            return
        }

        Show-Session $sessions
        $script:liveSessions = $sessions
        $script:lastUpdatedAt = Get-Date
        $totalMemoryGB = (($sessions | Measure-Object memoryMB -Sum).Sum / 1KB).ToString('0.0')
        $runningCount = @($sessions | Where-Object running).Count
        $script:liveStatus = "$runningCount running · $totalMemoryGB GB · updated $((Get-Date).ToString('HH:mm:ss'))"
        $statusLabel.Text = $script:liveStatus
        return
    }

    if ($form.WindowState -ne 'Minimized' -and (Get-Date) -ge $script:nextRefreshAt)
    {
        $script:refreshJobGeneration = $script:refreshGeneration
        $script:refreshJob = Start-ThreadJob { param($modulePath) Import-Module $modulePath; Get-ClaudeSession } -ArgumentList $ModulePath
    }
})

# A tracker set up while the window is open gets its button the next time the window comes to the front.
$form.Add_Activated({
    $script:nextRefreshAt = [datetime]::MinValue

    if (-not $script:trackerMode)
        { $trackerButton.Visible = Test-ClaudeTracker $TrackerPath }
})

$form.Add_FormClosing({
    $closeQuestion = 'A handover is still being written. Close anyway? Writing it stops, and the old session stays pinned.'

    if ($script:handoverJob -and $script:handoverJob.State -eq 'Running' -and -not (Confirm-Action $closeQuestion))
        { $_.Cancel = $true }
})

# A job's claude call (a listing, or a handover turn) is a child of this process and would outlive it; a handover turn left
# running would keep writing to the old session's transcript after you resume it.
$form.Add_FormClosed({
    $timer.Stop()

    foreach ($ownedClaude in @(Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.Parent.Id -eq $PID }))
        { $ownedClaude.Kill($true) }

    foreach ($job in @($script:refreshJob, $script:searchJob, $script:handoverJob))
    {
        if ($job)
            { Remove-Job $job -Force }
    }
})

Update-ActionState
$timer.Start()
[System.Windows.Forms.Application]::Run($form)

# The instance mutex goes first: while it exists the new window would only bring this closing one to the front, and exit. Started
# hidden, the new window would not show either, so it starts without a console window instead.
if ($script:reopenWindow)
{
    $instanceMutex.Dispose()
    $startInfo = [System.Diagnostics.ProcessStartInfo]@{ FileName = [Environment]::ProcessPath; CreateNoWindow = $true }

    foreach ($argument in '-NoProfile', '-STA', '-File', $PSCommandPath)
        { $startInfo.ArgumentList.Add($argument) }

    [System.Diagnostics.Process]::Start($startInfo) | Out-Null
}
