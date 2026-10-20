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
$LiveOnlyColumns = @('Pin', 'Kind', 'Status', 'Context', 'Memory')

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

    foreach ($control in @($pinButton, $pinMenuItem))
        { $control.Text = $pinText }
}

function New-Button([string]$Text, [scriptblock]$OnClick)
{
    $button = [System.Windows.Forms.Button]@{ Text = $Text; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(6, 2, 6, 2) }
    $button.Add_Click($OnClick)

    $button
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
        $tabTitle = if ($name) { $name } else { $repo }
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
    Size = [System.Drawing.Size]::new(1250, 520)
    StartPosition = 'CenterScreen'
    Font = [System.Drawing.Font]::new('Segoe UI', 10)
}

$topPanel = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Top'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(8) }
$labelMargin = [System.Windows.Forms.Padding]::new(3, 7, 3, 0)
$repoBox = [System.Windows.Forms.ComboBox]@{ DropDownStyle = 'DropDownList'; Width = 220 }
$repoBox.Items.AddRange([object[]]@(Get-ChildItem $settings.reposRoot -Directory | ForEach-Object Name))
$repoBox.SelectedItem = $settings.defaultRepo
$nameBox = [System.Windows.Forms.TextBox]@{ Width = 260 }
$nameBox.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $startAction } })

$searchHistoryButton = New-Button 'Search history' { if ($script:searchMode) { Exit-SearchMode } else { Enter-SearchMode } }
$searchHistoryButton.Margin = [System.Windows.Forms.Padding]::new(40, 3, 3, 3)
$colorModeButton = New-Button ($isDarkMode ? 'Light mode' : 'Dark mode') $colorModeAction
$colorModeButton.Margin = [System.Windows.Forms.Padding]::new(40, 3, 3, 3)
$colorModeButton.Visible = $canSwitchColorMode

$topPanel.Controls.AddRange(@(
    [System.Windows.Forms.Label]@{ Text = 'New session in'; AutoSize = $true; Margin = $labelMargin }
    $repoBox
    [System.Windows.Forms.Label]@{ Text = 'named'; AutoSize = $true; Margin = $labelMargin }
    $nameBox
    ($startButton = New-Button 'Start' $startAction)
    $searchHistoryButton
    $colorModeButton
))

$searchPanel = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Top'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(8, 0, 8, 8); Visible = $false }
$searchBox = [System.Windows.Forms.TextBox]@{ Width = 460 }
$searchBox.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Start-HistorySearch $searchBox.Text } })

$searchPanel.Controls.AddRange(@(
    [System.Windows.Forms.Label]@{ Text = 'Search history for'; AutoSize = $true; Margin = $labelMargin }
    $searchBox
    (New-Button 'Search' { Start-HistorySearch $searchBox.Text })
))

$modeHeader = [System.Windows.Forms.Label]@{
    Text = 'Live sessions'
    Dock = 'Top'
    Height = 34
    Padding = [System.Windows.Forms.Padding]::new(10, 6, 0, 0)
    Font = [System.Drawing.Font]::new('Segoe UI Semibold', 12)
}

$grid = [System.Windows.Forms.DataGridView]@{
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

$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.ColumnHeadersHeight = 34

$pinColumn = [System.Windows.Forms.DataGridViewButtonColumn]@{ Name = 'Pin'; HeaderText = ''; FlatStyle = 'Standard'; AutoSizeMode = 'None'; Width = 44 }
$pinColumn.DefaultCellStyle.Font = [System.Drawing.Font]::new('Segoe UI Symbol', 12)
$grid.Columns.Add($pinColumn) | Out-Null

foreach ($column in @(('Title', 32), ('Branch', 24), ('Repo', 9), ('Kind', 9), ('Status', 10), ('Active', 11), ('Context', 7), ('Memory', 8)))
{
    $grid.Columns.Add($column[0], $column[0]) | Out-Null
    $grid.Columns[$column[0]].FillWeight = $column[1]
    $grid.Columns[$column[0]].SortMode = 'Programmatic'
}

foreach ($column in @('Context', 'Memory'))
    { $grid.Columns[$column].DefaultCellStyle.Alignment = 'MiddleRight' }

$grid.Columns.Add('Match', 'Match') | Out-Null
$grid.Columns['Match'].FillWeight = 60
$grid.Columns['Match'].SortMode = 'NotSortable'
$grid.Columns['Match'].Visible = $false

# Dark mode leaves the column headers and the star buttons drawn in the light theme, and draws the sort arrow in a grey that
# hardly shows. So the headers are plain, without the current column's highlight, each star is drawn as a button like the
# window's own, lighter under the mouse, and a solid arrow in the header's text color goes over the sort arrow. The selected row's
# text is black on blue by default, so it stays white.
if ($isDarkMode)
{
    $grid.DefaultCellStyle.SelectionForeColor = $grid.DefaultCellStyle.ForeColor
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $grid.ColumnHeadersDefaultCellStyle.BackColor
    $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = $grid.ColumnHeadersDefaultCellStyle.ForeColor
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

$bottomPanel = [System.Windows.Forms.FlowLayoutPanel]@{ Dock = 'Bottom'; AutoSize = $true; Padding = [System.Windows.Forms.Padding]::new(8) }
$openButton = New-Button 'Open' $openAction
$renameButton = New-Button 'Rename' $renameAction
$pinButton = New-Button 'Pin' $pinAction
$stopButton = New-Button 'Stop' $stopAction
$handoverButton = New-Button 'Hand over' $handoverAction
$restoreButton = New-Button 'Restore pinned' $restoreAction
$restoreButton.Margin = [System.Windows.Forms.Padding]::new(40, 3, 3, 3)
$statusLabel = [System.Windows.Forms.Label]@{ AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(20, 9, 3, 0); ForeColor = [System.Drawing.SystemColors]::GrayText }
$handoverLabel = [System.Windows.Forms.Label]@{ AutoSize = $true; Margin = [System.Windows.Forms.Padding]::new(20, 9, 3, 0); ForeColor = [System.Drawing.Color]::DarkOrange; Visible = $false }
$bottomPanel.Controls.AddRange(@($openButton, $renameButton, $pinButton, $stopButton, $handoverButton, $restoreButton, $statusLabel, $handoverLabel))

$form.Controls.AddRange(@($grid, $searchPanel, $modeHeader, $topPanel, $bottomPanel))
$grid.BringToFront()
$form.KeyPreview = $true

$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq 'F')
    {
        $_.SuppressKeyPress = $true
        Enter-SearchMode
    }

    if ($_.KeyCode -eq 'Escape' -and $script:searchMode)
    {
        $_.SuppressKeyPress = $true
        Exit-SearchMode
    }
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

$form.Add_Activated({ $script:nextRefreshAt = [datetime]::MinValue })

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
