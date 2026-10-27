#Requires -Version 7.4
<#
.SYNOPSIS
Installs or updates ClaudeSessions for the current user, or removes it with -Uninstall.

.DESCRIPTION
Copies the ClaudeSessions module into your PowerShell 7 modules folder (or, with -Link, links it to this repo), adds
"Import-Module ClaudeSessions" to your pwsh profile, creates settings.json if there is none, and creates the Start menu
shortcut for the window. Running it again updates an existing install. -WhatIf shows the plan without changing anything; -Force
skips the questions.

.EXAMPLE
./Install.ps1 -ReposRoot C:\src -DefaultRepo my-repo

.EXAMPLE
./Install.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ReposRoot,
    [string]$DefaultRepo,
    [switch]$Link,
    [switch]$Uninstall,
    [switch]$RemoveData,
    [switch]$Force,
    [string]$ModulesPath = ($env:PSModulePath -split ';')[0],
    [string]$ProfilePath = (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts) 'Microsoft.PowerShell_profile.ps1'),
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Sessions.lnk'),
    [string]$DataPath = (Join-Path $env:LOCALAPPDATA 'ClaudeSessions')
)

$ErrorActionPreference = 'Stop'
$ModuleSource = Join-Path $PSScriptRoot 'ClaudeSessions'
$ModuleTarget = Join-Path $ModulesPath 'ClaudeSessions'
$ProfileLine = 'Import-Module ClaudeSessions'
$WindowAppId = 'ClaudeSessions.Window'

Add-Type -Namespace ClaudeSessionsInstall -Name Shortcut -MemberDefinition @'
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore
{
    void GetCount(out uint count);
    void GetAt(uint index, out PropertyKey key);
    void GetValue(ref PropertyKey key, out PropVariant value);
    void SetValue(ref PropertyKey key, ref PropVariant value);
    void Commit();
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct PropertyKey { public Guid FormatId; public uint PropertyId; }

[StructLayout(LayoutKind.Explicit)]
public struct PropVariant { [FieldOffset(0)] public ushort Type; [FieldOffset(8)] public IntPtr Value; [FieldOffset(16)] public IntPtr Padding; }

[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
static extern void SHGetPropertyStoreFromParsingName(string path, IntPtr bindContext, int flags, ref Guid interfaceId, out IPropertyStore store);

static PropertyKey AppUserModelId = new PropertyKey { FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), PropertyId = 5 };

static IPropertyStore Open(string path, bool writable)
{
    Guid interfaceId = typeof(IPropertyStore).GUID;
    IPropertyStore store;
    SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, writable ? 2 : 0, ref interfaceId, out store);
    return store;
}

// The ID the taskbar groups a shortcut's window under; the Properties dialog cannot set it.
public static void SetAppUserModelId(string path, string id)
{
    IPropertyStore store = Open(path, true);
    PropertyKey key = AppUserModelId;
    PropVariant value = new PropVariant { Type = 31, Value = Marshal.StringToCoTaskMemUni(id) };

    try { store.SetValue(ref key, ref value); store.Commit(); }
    finally { Marshal.FreeCoTaskMem(value.Value); Marshal.ReleaseComObject(store); }
}

public static string GetAppUserModelId(string path)
{
    IPropertyStore store = Open(path, false);
    PropertyKey key = AppUserModelId;
    PropVariant value;

    try { store.GetValue(ref key, out value); return value.Type == 31 ? Marshal.PtrToStringUni(value.Value) : null; }
    finally { Marshal.ReleaseComObject(store); }
}
'@

function Add-ProfileLine([string]$Path)
{
    $profileText = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }

    if (Test-ProfileLine $profileText)
        { return }

    $separator = if ($profileText -and -not $profileText.EndsWith("`n")) { [Environment]::NewLine } else { '' }

    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, "$profileText$separator$ProfileLine$([Environment]::NewLine)")
}

# Commands join the default to the repos folder, so it is a path from there (my-repo, or Clients\my-repo when repos are kept in
# folders); a full path would point them at a folder that does not exist.
function Assert-DefaultRepo([string]$ReposRoot, [string]$DefaultRepo)
{
    $isRelative = $DefaultRepo -and -not [IO.Path]::IsPathRooted($DefaultRepo) -and $DefaultRepo -notmatch '(^|[\\/])\.\.([\\/]|$)'

    if ($isRelative -and (Test-Path -LiteralPath (Join-Path $ReposRoot $DefaultRepo) -PathType Container))
        { return }

    $examples = @(Get-ChildItem -LiteralPath $ReposRoot -Directory | Select-Object -First 5 -ExpandProperty Name) -join ', '

    throw "The default repo is a folder under $ReposRoot, given as its path from there, such as: $examples. '$DefaultRepo' is not one."
}

function Assert-WindowClosed
{
    if ([Threading.Mutex]::TryOpenExisting('Local\ClaudeSessionsWindow', [ref]$null))
        { throw 'Close the Claude Sessions window first, so none of its files are in use.' }
}

# Files in the installed folder that this version does not ship: kept, and listed so you can tidy them up yourself.
function Get-UnknownModuleFile([string]$Source, [string]$Target)
{
    if (-not (Test-Path -LiteralPath $Target) -or (Test-ModuleLink $Target))
        { return }

    $shippedFiles = @(Get-ChildItem -LiteralPath $Source -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($Source, $_.FullName) })

    Get-ChildItem -LiteralPath $Target -File -Recurse |
        ForEach-Object { [IO.Path]::GetRelativePath($Target, $_.FullName) } |
        Where-Object { $_ -notin $shippedFiles }
}

function Install-ModuleFolder([string]$Source, [string]$Target, [switch]$Link)
{
    if ($Link)
    {
        if (Test-ModuleLink $Target)
        {
            if ((Get-Item -LiteralPath $Target).Target -eq $Source)
                { return }

            Remove-ModuleLink $Target
        }
        elseif (Test-Path -LiteralPath $Target)
        {
            Remove-ToRecycleBin $Target
        }

        New-Item -ItemType Directory -Force (Split-Path $Target) | Out-Null
        New-Item -ItemType Junction -Path $Target -Target $Source | Out-Null
        return
    }

    if (Test-ModuleLink $Target)
        { Remove-ModuleLink $Target }

    foreach ($file in Get-ChildItem -LiteralPath $Source -File -Recurse)
    {
        $targetFile = Join-Path $Target ([IO.Path]::GetRelativePath($Source, $file.FullName))

        New-Item -ItemType Directory -Force (Split-Path $targetFile) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force
        Unblock-File -LiteralPath $targetFile
    }
}

function New-SettingsFile([string]$Path, [string]$ReposRoot, [string]$DefaultRepo)
{
    $settings = [ordered]@{ reposRoot = $ReposRoot; defaultRepo = $DefaultRepo }

    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $settings))
}

# A junction is removed as a link: deleting it like a folder could reach through it and remove the repo's files.
function Remove-ModuleLink([string]$Path)
{
    [IO.Directory]::Delete($Path, $false)
}

function Remove-ProfileLine([string]$Path)
{
    if (-not (Test-Path -LiteralPath $Path))
        { return }

    $lines = [IO.File]::ReadAllLines($Path)
    $keptLines = @($lines | Where-Object { -not (Test-ProfileLine $_) })

    if ($keptLines.Count -ne $lines.Count)
        { [IO.File]::WriteAllLines($Path, [string[]]$keptLines) }
}

function Remove-ToRecycleBin([string]$Path)
{
    Add-Type -AssemblyName Microsoft.VisualBasic

    if (Test-Path -LiteralPath $Path -PathType Container)
        { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin') }
    elseif (Test-Path -LiteralPath $Path)
        { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin') }
}

# Runs the window without a console and with its own taskbar identity, so a pin of this shortcut groups with the open window.
function Set-WindowShortcut([string]$Path, [string]$ModuleFolder)
{
    $pwshPath = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $pwshPath
    $shortcut.Arguments = "-NoProfile -STA -WindowStyle Hidden -File `"$(Join-Path $ModuleFolder 'ClaudeSessionsWindow.ps1')`""
    $shortcut.IconLocation = "$(Join-Path $ModuleFolder 'ClaudeSessions.ico'),0"
    $shortcut.Description = 'Claude Code sessions'

    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    $shortcut.Save()
    [ClaudeSessionsInstall.Shortcut]::SetAppUserModelId($Path, $WindowAppId)
}

function Test-ModuleLink([string]$Path)
{
    (Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path -Force).LinkType -in 'Junction', 'SymbolicLink'
}

function Test-ProfileLine([string]$Text)
{
    $Text -match '(?m)^\s*Import-Module\s+ClaudeSessions\s*$'
}

function Confirm-Step([string]$Question)
{
    $Force -or $PSCmdlet.ShouldContinue($Question, 'ClaudeSessions')
}

function Invoke-Install
{
    Assert-WindowClosed

    foreach ($command in 'claude', 'wt')
    {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue))
            { Write-Warning "$command is not on PATH; ClaudeSessions needs it to run sessions." }
    }

    $settingsPath = Join-Path $DataPath 'settings.json'

    if (-not (Test-Path -LiteralPath $settingsPath))
    {
        $settingsReposRoot = if ($ReposRoot) { $ReposRoot } else { Read-Host 'Folder that holds your repos' }

        if (-not (Test-Path -LiteralPath $settingsReposRoot -PathType Container))
            { throw "$settingsReposRoot is not a folder." }

        $settingsDefaultRepo = if ($DefaultRepo) { $DefaultRepo } else { Read-Host "Repo to use when a command names none, as its path under $settingsReposRoot (my-repo, or Clients\my-repo)" }
        Assert-DefaultRepo $settingsReposRoot $settingsDefaultRepo

        if ($PSCmdlet.ShouldProcess($settingsPath, 'Create the settings'))
            { New-SettingsFile $settingsPath $settingsReposRoot $settingsDefaultRepo }
    }

    $unknownFiles = @(Get-UnknownModuleFile $ModuleSource $ModuleTarget)
    $replacesFolder = $Link -and (Test-Path -LiteralPath $ModuleTarget) -and -not (Test-ModuleLink $ModuleTarget)
    $moduleAction = if ($Link) { "Link to $ModuleSource" } else { "Copy the module from $ModuleSource" }

    if ($replacesFolder -and -not (Confirm-Step "$ModuleTarget is a copy; the link replaces it, and the copy goes to the Recycle Bin. Continue?"))
        { return }

    if ($PSCmdlet.ShouldProcess($ModuleTarget, $moduleAction))
        { Install-ModuleFolder $ModuleSource $ModuleTarget -Link:$Link }

    $profileText = if (Test-Path -LiteralPath $ProfilePath) { [IO.File]::ReadAllText($ProfilePath) } else { '' }

    if (-not (Test-ProfileLine $profileText) -and $PSCmdlet.ShouldProcess($ProfilePath, "Add '$ProfileLine'"))
    {
        if (Confirm-Step "Add '$ProfileLine' to $ProfilePath, so the cc* commands load in every pwsh tab?")
            { Add-ProfileLine $ProfilePath }
        else
            { Write-Warning "Without '$ProfileLine' in your profile, the commands load only after you import the module yourself." }
    }

    if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Create the Start menu shortcut'))
        { Set-WindowShortcut $ShortcutPath $ModuleTarget }

    if ($unknownFiles -and $Link)
        { Write-Host "The previous copy went to the Recycle Bin, including files this version does not ship: $($unknownFiles -join ', ')" }
    elseif ($unknownFiles)
        { Write-Host "Left in $ModuleTarget, not part of this version: $($unknownFiles -join ', ')" }

    if (-not $WhatIfPreference)
        { Write-Host "Installed. Open a new pwsh tab for the commands (cchelp lists them); 'Claude Sessions' in the Start menu opens the window." }
}

function Invoke-Uninstall
{
    Assert-WindowClosed

    $dataNote = if ($RemoveData) { ", and your pins, labels, handovers and search cache in $DataPath" } else { '' }

    if (-not (Confirm-Step "Remove the Start menu shortcut, the profile line and $ModuleTarget$dataNote? Folders and files go to the Recycle Bin."))
        { return }

    if ((Test-Path -LiteralPath $ShortcutPath) -and $PSCmdlet.ShouldProcess($ShortcutPath, 'Remove the shortcut'))
        { Remove-ToRecycleBin $ShortcutPath }

    if ($PSCmdlet.ShouldProcess($ProfilePath, "Remove '$ProfileLine'"))
        { Remove-ProfileLine $ProfilePath }

    if ((Test-Path -LiteralPath $ModuleTarget) -and $PSCmdlet.ShouldProcess($ModuleTarget, 'Remove the module'))
    {
        if (Test-ModuleLink $ModuleTarget)
            { Remove-ModuleLink $ModuleTarget }
        else
            { Remove-ToRecycleBin $ModuleTarget }
    }

    if ($RemoveData -and (Test-Path -LiteralPath $DataPath) -and $PSCmdlet.ShouldProcess($DataPath, 'Remove your data'))
        { Remove-ToRecycleBin $DataPath }

    if (-not $WhatIfPreference)
        { Write-Host 'Uninstalled. Open pwsh tabs keep the commands until they are closed.' }
}

# Dot-sourced (by the tests) it only defines the functions.
if ($MyInvocation.InvocationName -ne '.')
{
    if ($Uninstall)
        { Invoke-Uninstall }
    else
        { Invoke-Install }
}
