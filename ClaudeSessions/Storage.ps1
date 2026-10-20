# Pins, labels and settings: small JSON files in %LOCALAPPDATA%\ClaudeSessions, outside the module so a shared copy carries no
# per-user data.

$ClaudeLabelsPath = Join-Path $ClaudeDataPath 'labels.json'
$ClaudePinsPath = Join-Path $ClaudeDataPath 'pins.json'
$ClaudeSettingsPath = Join-Path $ClaudeDataPath 'settings.json'

# One write, so a handover never leaves both sessions pinned, or neither.
function Add-ClaudePin($Session, [string]$ReplacedSessionId)
{
    Invoke-WithClaudeFileLock {
        $pins = @(Get-ClaudePin | Where-Object { $_.sessionId -ne $Session.sessionId -and $_.sessionId -ne $ReplacedSessionId })
        $pins += [pscustomobject]@{ sessionId = $Session.sessionId; name = $Session.name; cwd = $Session.cwd }

        Save-ClaudePin $pins
    }
}

function Get-ClaudeLabel
{
    (Read-ClaudeJsonFile $ClaudeLabelsPath -AsHashtable) ?? @{}
}

function Get-ClaudePin
{
    Read-ClaudeJsonFile $ClaudePinsPath
}

function Get-ClaudeSessionsSetting
{
    $settings = Read-ClaudeJsonFile $ClaudeSettingsPath

    if (-not $settings)
        { throw "No settings yet: create $ClaudeSettingsPath with reposRoot and defaultRepo." }

    $settings
}

# The window, its handover job and terminal tabs all change pins and labels, so each change holds this lock from its read to its
# write. A mutex belongs to the thread that took it, and a runspace runs a call on one thread, so the release happens there too.
function Invoke-WithClaudeFileLock([scriptblock]$Action)
{
    $mutex = [System.Threading.Mutex]::new($false, 'Local\ClaudeSessionsFiles')
    $owned = $false

    try
    {
        try
        {
            $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        }
        catch [System.Threading.AbandonedMutexException]
        {
            $owned = $true
        }

        if (-not $owned)
            { throw 'Another ClaudeSessions command has held the pins and labels for 10 seconds; try again.' }

        & $Action
    }
    finally
    {
        if ($owned)
            { $mutex.ReleaseMutex() }

        $mutex.Dispose()
    }
}

# A missing or empty file means no data yet; a corrupt one is reported rather than read as empty and overwritten.
function Read-ClaudeJsonFile([string]$Path, [switch]$AsHashtable)
{
    if (-not (Test-Path -LiteralPath $Path))
        { return }

    $json = Get-Content -LiteralPath $Path -Raw

    if ([string]::IsNullOrWhiteSpace($json))
        { return }

    try
    {
        $json | ConvertFrom-Json -AsHashtable:$AsHashtable -ErrorAction Stop
    }
    catch
    {
        throw "$Path is not valid JSON ($($_.Exception.Message)); fix or delete it."
    }
}

# To the Recycle Bin, so a wrong removal can be undone.
function Remove-ClaudeFile([string]$Path)
{
    if (-not (Test-Path -LiteralPath $Path))
        { return }

    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
}

function Remove-ClaudePin([string]$SessionId)
{
    Invoke-WithClaudeFileLock { Save-ClaudePin @(Get-ClaudePin | Where-Object sessionId -ne $SessionId) }
}

# Swapped in from a temporary file, so a reader never sees a half-written one.
function Save-ClaudeFile([string]$Path, [string]$Content)
{
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"

    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($temporaryPath, $Content)
    [IO.File]::Move($temporaryPath, $Path, $true)
}

function Save-ClaudePin([object[]]$Pins)
{
    Save-ClaudeFile $ClaudePinsPath (ConvertTo-Json -InputObject @($Pins))
}

# An empty label goes back to Claude's own title.
function Set-ClaudeLabel([string]$SessionId, [string]$Label)
{
    Invoke-WithClaudeFileLock {
        $labels = Get-ClaudeLabel

        if ($Label.Trim())
            { $labels[$SessionId] = $Label.Trim() }
        else
            { $labels.Remove($SessionId) }

        Save-ClaudeFile $ClaudeLabelsPath (ConvertTo-Json -InputObject $labels)
    }
}
