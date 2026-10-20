#Requires -Version 7.4
<#
Takes the README screenshots from made-up sessions. The window runs with its home folder, app data and claude pointed at a
temporary folder, so none of your own sessions, pins or labels appear or change. Close your own Claude Sessions window first:
the window runs one instance at a time.
#>
param([string]$OutputFolder = $PSScriptRoot)

$ErrorActionPreference = 'Stop'

if ([Threading.Mutex]::TryOpenExisting('Local\ClaudeSessionsWindow', [ref]$null))
    { throw 'Close the Claude Sessions window first; it runs one instance at a time.' }

Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace ClaudeSessionsScreenshot -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);
'@

# Per-monitor aware, so window bounds come back in real pixels at any display scaling.
[ClaudeSessionsScreenshot.Native]::SetProcessDpiAwarenessContext([IntPtr]-4) | Out-Null

$demoRoot = Join-Path ([IO.Path]::GetTempPath()) "ClaudeSessionsDemo-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$reposRoot = Join-Path $demoRoot 'repos'
$dataPath = Join-Path $demoRoot 'AppData\Local\ClaudeSessions'
$projectsPath = Join-Path $demoRoot '.claude\projects'
$windowScript = Join-Path $PSScriptRoot '..\ClaudeSessions\ClaudeSessionsWindow.ps1'
$placeholderProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

$sessions = @(
    @{ Title = 'Checkout page redesign'; Repo = 'web-shop'; Branch = 'feature/checkout-v2'; Kind = 'interactive'; Status = 'busy'; MinutesAgo = 0; Context = 142000; Pinned = $true
       Prompt = 'Move the address form into its own step and keep the cart summary visible on the right.'
       Reply = 'The address step now validates on blur, and the summary panel stays sticky on wide screens.' }
    @{ Title = 'Invoice PDF export'; Repo = 'billing-api'; Branch = 'feature/pdf-export'; Kind = 'interactive'; Status = 'idle'; MinutesAgo = 4; Context = 88000; Pinned = $true
       Prompt = 'Export invoices as PDF with the company letterhead and a page footer.'
       Reply = 'The export renders each invoice through the template and streams the PDF back to the client.' }
    @{ Title = 'Flaky login test'; Repo = 'mobile-app'; Branch = 'fix/login-timeout'; Kind = 'interactive'; Status = 'idle'; MinutesAgo = 26; Context = 61000; Pinned = $false
       Prompt = 'The login test fails about one run in ten with a timeout on the second screen. Find out why.'
       Reply = 'The test waited for an animation that is skipped on fast devices, so the timeout only hit some runs.' }
    @{ Title = 'Nightly backup job'; Repo = 'infra'; Branch = 'main'; Kind = 'bg'; Status = 'idle'; State = 'done'; MinutesAgo = 130; Context = 35000; Pinned = $false
       Prompt = 'Check last night''s backup job and summarise anything that failed.'
       Reply = 'All four databases were backed up; the logs volume took longer than usual but finished.' }
    @{ Title = 'Search API caching'; Repo = 'billing-api'; Branch = 'feature/cache-layer'; Kind = 'stopped'; MinutesAgo = 1500; Context = 120000; Pinned = $true
       Prompt = 'Put a cache in front of the search endpoint and expire entries after five minutes.'
       Reply = 'Search results are cached per query for five minutes, and a request timeout falls back to the database.' }
    @{ Title = 'Release notes 3.2'; Repo = 'web-shop'; Branch = 'main'; Kind = 'stopped'; MinutesAgo = 4400; Context = 42000; Pinned = $true
       Prompt = 'Draft the release notes for 3.2 from the merged pull requests.'
       Reply = 'The notes group the changes into checkout, accounts and fixes, with the breaking change called out first.' }
    @{ Title = 'Payment webhook retries'; Repo = 'billing-api'; Branch = 'fix/webhook-retries'; Kind = 'stopped'; MinutesAgo = 13000; Context = 77000; Pinned = $false
       Prompt = 'Webhooks from the payment provider sometimes time out. Add retries with a backoff.'
       Reply = 'Failed webhooks are retried three times with a growing delay, and a timeout no longer drops the event.' }
)

function Write-Transcript($Session, [string]$SessionId, [string]$Cwd)
{
    $projectPath = Join-Path $projectsPath "C--demo-$($Session.Repo)"
    $transcriptPath = Join-Path $projectPath "$SessionId.jsonl"
    $usage = [ordered]@{ input_tokens = 2000; cache_read_input_tokens = $Session.Context - 2000; cache_creation_input_tokens = 0 }

    $records = @(
        [ordered]@{ type = 'user'; cwd = $Cwd; gitBranch = $Session.Branch; message = [ordered]@{ role = 'user'; content = $Session.Prompt } }
        [ordered]@{ type = 'assistant'; cwd = $Cwd; gitBranch = $Session.Branch; message = [ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'text'; text = $Session.Reply }); usage = $usage } }
        [ordered]@{ type = 'custom-title'; customTitle = $Session.Title; sessionId = $SessionId }
        [ordered]@{ type = 'last-prompt'; lastPrompt = $Session.Prompt; sessionId = $SessionId }
    )

    New-Item -ItemType Directory -Force $projectPath | Out-Null
    [IO.File]::WriteAllLines($transcriptPath, [string[]]@($records | ForEach-Object { ConvertTo-Json -InputObject $_ -Compress -Depth 6 }))
    (Get-Item -LiteralPath $transcriptPath).LastWriteTime = (Get-Date).AddMinutes(-$Session.MinutesAgo)
}

# Draws the window into a bitmap, cropped to its visible frame; PrintWindow works even while other windows cover it.
function Save-WindowImage([IntPtr]$Window, [string]$Path)
{
    $windowRect = [ClaudeSessionsScreenshot.Native+Rect]::new()
    $frameRect = [ClaudeSessionsScreenshot.Native+Rect]::new()
    [ClaudeSessionsScreenshot.Native]::GetWindowRect($Window, [ref]$windowRect) | Out-Null
    [ClaudeSessionsScreenshot.Native]::DwmGetWindowAttribute($Window, 9, [ref]$frameRect, 16) | Out-Null

    $fullImage = [System.Drawing.Bitmap]::new($windowRect.Right - $windowRect.Left, $windowRect.Bottom - $windowRect.Top)
    $graphics = [System.Drawing.Graphics]::FromImage($fullImage)
    $deviceContext = $graphics.GetHdc()
    [ClaudeSessionsScreenshot.Native]::PrintWindow($Window, $deviceContext, 2) | Out-Null
    $graphics.ReleaseHdc($deviceContext)
    $graphics.Dispose()

    $frame = [System.Drawing.Rectangle]::new(
        $frameRect.Left - $windowRect.Left,
        $frameRect.Top - $windowRect.Top,
        $frameRect.Right - $frameRect.Left,
        $frameRect.Bottom - $frameRect.Top
    )
    $image = $fullImage.Clone($frame, $fullImage.PixelFormat)
    $image.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $image.Dispose()
    $fullImage.Dispose()
}

function Find-WindowElement($Window, [string]$Name, [string]$ControlType)
{
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::$ControlType)
    )

    [System.Windows.Automation.AutomationElement]::FromHandle($Window).FindFirst('Descendants', $condition)
}

function Invoke-WindowButton($Window, [string]$Name)
{
    (Find-WindowElement $Window $Name 'Button').GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

try
{
    New-Item -ItemType Directory -Force $dataPath, $projectsPath | Out-Null

    foreach ($repo in $sessions.Repo | Sort-Object -Unique)
        { New-Item -ItemType Directory -Force (Join-Path $reposRoot $repo) | Out-Null }

    $agents = [System.Collections.Generic.List[object]]::new()
    $pins = [System.Collections.Generic.List[object]]::new()

    foreach ($session in $sessions)
    {
        $sessionId = [guid]::NewGuid().ToString()
        $cwd = Join-Path $reposRoot $session.Repo
        Write-Transcript $session $sessionId $cwd

        if ($session.Pinned)
            { $pins.Add([ordered]@{ sessionId = $sessionId; name = $session.Title; cwd = $cwd }) }

        if ($session.Kind -eq 'stopped')
            { continue }

        # An idle pwsh stands in for each running session's process, so the Memory column has something real to show.
        $placeholder = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 600' -WindowStyle Hidden -PassThru
        $placeholderProcesses.Add($placeholder)

        $agent = [ordered]@{
            pid = $placeholder.Id
            cwd = $cwd
            kind = $session.Kind
            startedAt = [DateTimeOffset]::new($placeholder.StartTime).ToUnixTimeMilliseconds()
            sessionId = $sessionId
            name = $session.Repo
            status = $session.Status
        }

        if ($session.Kind -ne 'interactive')
        {
            $agent.id = $sessionId.Substring(0, 8)
            $agent.state = $session.State
        }

        $agents.Add($agent)
    }

    Set-Content (Join-Path $demoRoot 'agents.json') (ConvertTo-Json -InputObject @($agents) -Depth 4)
    Set-Content (Join-Path $dataPath 'pins.json') (ConvertTo-Json -InputObject @($pins) -Depth 4)
    Set-Content (Join-Path $dataPath 'settings.json') (ConvertTo-Json -InputObject ([ordered]@{ reposRoot = $reposRoot; defaultRepo = 'web-shop' }))
    Set-Content (Join-Path $demoRoot 'claude.cmd') @'
@echo off
if "%1"=="agents" type "%~dp0agents.json" & exit /b 0
if "%1"=="--version" echo 2.1.0 (Claude Code) & exit /b 0
exit /b 1
'@

    $environment = @{ USERPROFILE = $demoRoot; LOCALAPPDATA = Join-Path $demoRoot 'AppData\Local'; PATH = "$demoRoot;$env:PATH" }
    # Started hidden, the window would not show either, so its console output goes to files instead.
    $windowErrorsPath = Join-Path $demoRoot 'window-errors.txt'
    $windowArguments = '-NoProfile', '-STA', '-File', "`"$windowScript`""
    $windowProcess = Start-Process pwsh -ArgumentList $windowArguments -Environment $environment -PassThru -RedirectStandardError $windowErrorsPath -RedirectStandardOutput (Join-Path $demoRoot 'window-output.txt')
    $deadline = (Get-Date).AddSeconds(30)

    do
    {
        if ((Get-Date) -gt $deadline -or $windowProcess.HasExited)
            { throw "The demo window did not open: $(Get-Content -LiteralPath $windowErrorsPath -Raw -ErrorAction SilentlyContinue)" }

        Start-Sleep -Milliseconds 250
        $windowProcess.Refresh()
    }
    while ($windowProcess.MainWindowHandle -eq [IntPtr]::Zero)

    $window = $windowProcess.MainWindowHandle
    Start-Sleep -Seconds 5
    Save-WindowImage $window (Join-Path $OutputFolder 'screenshot.png')

    # The search box sits below the new-session name box, the window's other text box.
    Invoke-WindowButton $window 'Search history'
    $editCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $textBoxes = [System.Windows.Automation.AutomationElement]::FromHandle($window).FindAll('Descendants', $editCondition)
    $searchBox = $textBoxes | Sort-Object { $_.Current.BoundingRectangle.Top } | Select-Object -Last 1
    $searchBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('timeout')
    Invoke-WindowButton $window 'Search'
    Start-Sleep -Seconds 5
    Save-WindowImage $window (Join-Path $OutputFolder 'screenshot-search.png')
}
finally
{
    if ($windowProcess -and -not $windowProcess.HasExited)
        { $windowProcess.Kill($true) }

    foreach ($placeholder in $placeholderProcesses)
    {
        if (-not $placeholder.HasExited)
            { $placeholder.Kill() }
    }

    # Everything in it was made by this run, and the Recycle Bin would only fill up with demo files.
    if (Test-Path -LiteralPath $demoRoot)
        { Remove-Item -LiteralPath $demoRoot -Recurse -Force }
}
