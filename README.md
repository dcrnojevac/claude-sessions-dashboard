# claude-sessions-dashboard

Small utility for overseeing Claude Code sessions: a window and a set of `cc*` PowerShell commands to see what is running with
its title, branch, last activity, context size and memory, start sessions in a repo, rename them, search what was said in past
sessions, hand a long session over to a fresh one, and pin the ones you want back after a reboot.

![The Claude Sessions window listing running and pinned sessions](Docs/screenshot.png)

## Requirements

- Windows, PowerShell 7.4 or later (`pwsh`), Windows Terminal
- Claude Code on `PATH`, recent enough for `claude agents --json`

## Setup

1. Copy the `ClaudeSessions` folder of this repo into your PowerShell 7 modules folder, usually `Documents\PowerShell\Modules\`.
   Run `$env:PSModulePath -split ';' | Select-Object -First 1` in pwsh 7 to see where yours is.
   If the files came from a downloaded zip, unblock them once: `Get-ChildItem <that folder> -Recurse | Unblock-File`.
2. Open your profile with `notepad $PROFILE` (in pwsh 7) and add this line:
   ```powershell
   Import-Module ClaudeSessions
   ```
3. Create `%LOCALAPPDATA%\ClaudeSessions\settings.json`, pointing at the folder that holds your repos:
   ```json
   {
     "reposRoot": "C:\\src",
     "defaultRepo": "my-repo"
   }
   ```
4. Make PowerShell 7 your default Windows Terminal profile (Settings > Startup > Default profile > PowerShell). Windows
   PowerShell 5.1 reads a different profile, so the commands don't exist there.
5. Optional: a Start menu shortcut for the window, with target
   `pwsh.exe -NoProfile -STA -WindowStyle Hidden -File "<modules folder>\ClaudeSessions\ClaudeSessionsWindow.ps1"` and the icon
   `ClaudeSessions.ico` from the same folder. Otherwise type `ccui`. A taskbar pin of that shortcut opens the window, but the
   open window only shows under the pin when the shortcut also carries the AppUserModelID `ClaudeSessions.Window`, which the
   Properties dialog cannot set; without it the window gets its own taskbar button next to the pin.

Open a new tab and run `cchelp` for the commands. Commands that take a number use the numbers from the last `ccl` in that tab.

**Search history** (or Ctrl+F) in the window, and `cch <words>` in a terminal, find past sessions by what was said in them:
your prompts, Claude's replies and the titles, not the context Claude Code injects. Every word and `"quoted phrase"` must appear,
matched from the start of a word (`part` finds partition, `notifier` finds EtlRunNotifier, `rent` does not find current). Esc
goes back to the live list, and so does opening a result. Open is the only action on results; pin, rename, stop and hand over
work from the live list. Claude Code deletes transcripts after `cleanupPeriodDays` (30 by default, in `~/.claude/settings.json`),
so search only reaches back that far; raise it if you want more.

![History search for "timeout", listing three sessions with the matching text](Docs/screenshot-search.png)

**Hand over** (button, right-click, or `cchandover <title|#>`) continues an idle session in a fresh one. After asking, it stops
the session, has it write a handover document in one more turn, saves it to `%LOCALAPPDATA%\ClaudeSessions\handovers\`, then
starts `<title> (2)` in a new tab with a prompt to read it, and pins the new session in place of the old one. That turn re-reads
the whole conversation, so on a large session it is one expensive turn. If no handover comes back, the old session stays pinned
and can be resumed.

Launching the window while it is already open brings the open one to the front. **Memory** is each session's private memory
(what counts against the Windows commit limit), not its working set.

## What it touches

- **Runs** `claude agents --json` to list sessions, and `claude`, `claude --resume` or `claude attach` in a new Windows Terminal
  tab when you click or type the matching action. Stop ends the session's process (its pid re-read from `claude agents` right
  before), or runs `claude stop` for a background session; the window and `ccstop` both ask first. The conversation itself is
  never deleted, so a stopped session can be resumed. Hand over also runs `claude -p --resume` in the session's folder, which
  adds the handover turn to the old conversation.
- **Reads** the end of each session's transcript under `~\.claude\projects\` (the last 256 KB, up to 4 MB when the title is
  further back) for its title, branch, last prompt and context size, and for search the whole transcript, once per change. It
  never writes there.
- **Writes** only `pins.json`, `labels.json`, the handover documents (`handovers\`) and the search cache (`history\`, the
  extracted text of each session) next to `settings.json` in `%LOCALAPPDATA%\ClaudeSessions\`, each through a temporary file
  that replaces the old one, so nothing reads a half-written file. Deleting `history\` just makes the next search rebuild it.
  The only file the tool ever removes is a search-cache entry whose transcript Claude Code has already deleted, and that goes to
  the Recycle Bin.

## When Claude Code changes

The tool reads Claude Code's own session list (`claude agents --json`) and its internal transcript format, and both can change
with any update. It is built to stop rather than guess:

- If `claude agents --json` prints anything but a list, or an entry lacks a field the tool acts on, every command and the window
  report the change and do nothing.
- Every `claude` call the tool waits on has a time limit (20 seconds for listing and stopping, 15 minutes for a handover turn)
  and is killed past it. Closing the window also ends any `claude` it started that is still running.
- Open, Restore, `cco` and Hand over check again right before resuming, and refuse a session that Claude lists as running, that
  any `claude` process names on its command line (a tab still starting, or a handover being written, in any shell), or that was
  opened here in the last 15 seconds, so a stale list or a second click cannot start a second copy of a session.
- Stop only ends a session whose status is `idle` (or `busy`, after asking or with `-Force`), and only when the process is a
  `claude` started when Claude says the session started.
- Hand over changes the pins only after the handover came back from the resumed session itself and the new session is running
  under the id it was given.
- The search cache is left alone if no transcripts are found at all.

Titles, branches and context sizes are only displayed, so a transcript format change makes them fall back to plain session names
rather than stopping the tool.

## Tests

The tests use Pester 5 or later (`Install-Module Pester -Scope CurrentUser -SkipPublisherCheck`; Windows ships the older 3.4).
From the repo root:

```powershell
Invoke-Pester ./Tests
```

They never touch your sessions, pins or labels: Claude Code, processes and tabs are mocked, pins and labels go to Pester's
temporary drive, and the runner tests start `pwsh` in place of `claude`.

The screenshots come from `Docs/New-Screenshot.ps1`, which runs the window against made-up sessions in a temporary folder (close
your own window first), and the icon from `Docs/New-Icon.ps1`.

## Removing it

Delete the module folder, remove the `Import-Module` line from your profile, and delete `%LOCALAPPDATA%\ClaudeSessions\`.
