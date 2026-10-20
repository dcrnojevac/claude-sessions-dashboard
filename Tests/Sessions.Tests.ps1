BeforeAll {
    Import-Module "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.psm1" -Force

    $sessionId = '11111111-2222-3333-4444-555555555555'
    $startedMs = [DateTimeOffset]::Now.AddMinutes(-5).ToUnixTimeMilliseconds()
    $startedAt = [DateTimeOffset]::FromUnixTimeMilliseconds($startedMs).LocalDateTime
    $runningSession = [pscustomobject]@{ sessionId = $sessionId; title = 'Fake'; cwd = $TestDrive; running = $true }
    $stoppedSession = [pscustomobject]@{ sessionId = $sessionId; title = 'Fake'; cwd = $TestDrive; running = $false }

    function Set-AgentsOutput([string]$Json)
    {
        Mock Invoke-ClaudeCommand -ModuleName ClaudeSessions -ParameterFilter { $ClaudeArguments[0] -eq 'agents' } -MockWith ([scriptblock]::Create("@'`n$Json`n'@"))
    }

    function Get-InteractiveEntry([string]$Status)
    {
        "[{`"pid`":4242,`"cwd`":`"C:\\x`",`"kind`":`"interactive`",`"startedAt`":$startedMs,`"sessionId`":`"$sessionId`",`"status`":`"$Status`"}]"
    }
}

Describe 'Get-ClaudeRunningSession' {
    BeforeEach {
        Mock Invoke-ClaudeCommand -ModuleName ClaudeSessions -ParameterFilter { $ClaudeArguments[0] -eq '--version' } { '9.9.9 (stub)' }
    }

    It 'stops everything when the listing prints nothing' {
        Set-AgentsOutput ''
        { Get-ClaudeRunningSession } | Should -Throw '*no list of sessions*'
    }

    It 'stops everything when the listing is not a list' {
        Set-AgentsOutput '{"sessions":[]}'
        { Get-ClaudeRunningSession } | Should -Throw '*no list of sessions*'
    }

    It 'reads an empty list as nothing running' {
        Set-AgentsOutput '[]'
        @(Get-ClaudeRunningSession).Count | Should -Be 0
    }

    It 'stops everything when an entry has no <Field>' -ForEach @(
        @{ Field = 'sessionId'; Json = "[{`"pid`":1,`"cwd`":`"C:\\x`",`"kind`":`"interactive`",`"startedAt`":1,`"status`":`"idle`"}]" }
        @{ Field = 'pid'; Json = "[{`"cwd`":`"C:\\x`",`"kind`":`"interactive`",`"startedAt`":1,`"sessionId`":`"11111111-2222-3333-4444-555555555555`",`"status`":`"idle`"}]" }
        @{ Field = 'id'; Json = "[{`"cwd`":`"C:\\x`",`"kind`":`"bg`",`"sessionId`":`"11111111-2222-3333-4444-555555555555`",`"status`":`"idle`"}]" }
    ) {
        Set-AgentsOutput $Json
        { Get-ClaudeRunningSession } | Should -Throw "*no usable '$Field'*"
    }
}

Describe 'Stop-ClaudeSession' {
    BeforeEach {
        Mock Stop-Process -ModuleName ClaudeSessions -RemoveParameterType InputObject { }
        Mock Get-Process -ModuleName ClaudeSessions { [pscustomobject]@{ ProcessName = 'claude'; StartTime = $startedAt } }
    }

    It 'stops a matching idle claude process' {
        Set-AgentsOutput (Get-InteractiveEntry 'idle')
        Stop-ClaudeSession $runningSession
        Should -Invoke Stop-Process -ModuleName ClaudeSessions -Times 1 -Exactly
    }

    It 'stops nothing when the status is unknown' {
        Set-AgentsOutput (Get-InteractiveEntry 'waiting')
        { Stop-ClaudeSession $runningSession } | Should -Throw "*status 'waiting'*"
        Should -Invoke Stop-Process -ModuleName ClaudeSessions -Times 0
    }

    It 'stops nothing when the pid is not a claude process' {
        Mock Get-Process -ModuleName ClaudeSessions { [pscustomobject]@{ ProcessName = 'pwsh'; StartTime = $startedAt } }
        Set-AgentsOutput (Get-InteractiveEntry 'idle')
        { Stop-ClaudeSession $runningSession } | Should -Throw '*nothing was stopped*'
        Should -Invoke Stop-Process -ModuleName ClaudeSessions -Times 0
    }

    It 'stops nothing when the claude process started at another time' {
        Mock Get-Process -ModuleName ClaudeSessions { [pscustomobject]@{ ProcessName = 'claude'; StartTime = Get-Date } }
        Set-AgentsOutput (Get-InteractiveEntry 'idle')
        { Stop-ClaudeSession $runningSession } | Should -Throw '*nothing was stopped*'
        Should -Invoke Stop-Process -ModuleName ClaudeSessions -Times 0
    }

    It 'stops a busy session only with -Force' {
        Set-AgentsOutput (Get-InteractiveEntry 'busy')
        { Stop-ClaudeSession $runningSession } | Should -Throw '*is busy*'
        Stop-ClaudeSession $runningSession -Force
        Should -Invoke Stop-Process -ModuleName ClaudeSessions -Times 1 -Exactly
    }

    It 'stops a background session through claude stop' {
        Mock Invoke-ClaudeCommand -ModuleName ClaudeSessions -ParameterFilter { $ClaudeArguments[0] -eq 'stop' } { }
        Set-AgentsOutput "[{`"cwd`":`"C:\\x`",`"kind`":`"bg`",`"id`":`"ab12cd34`",`"sessionId`":`"$sessionId`",`"status`":`"idle`"}]"
        Stop-ClaudeSession $runningSession
        Should -Invoke Invoke-ClaudeCommand -ModuleName ClaudeSessions -ParameterFilter { $ClaudeArguments -join ' ' -eq 'stop ab12cd34' } -Times 1 -Exactly
    }
}

Describe 'Resume-ClaudeInTab' {
    BeforeEach {
        InModuleScope ClaudeSessions { $RecentlyResumed.Clear() }
        Mock Open-ClaudeTab -ModuleName ClaudeSessions { }
        Mock Get-Process -ModuleName ClaudeSessions { }
        Set-AgentsOutput '[]'
    }

    It 'opens a stopped session once' {
        Resume-ClaudeInTab $stoppedSession
        Should -Invoke Open-ClaudeTab -ModuleName ClaudeSessions -Times 1 -Exactly
    }

    It 'refuses a session Claude lists as running' {
        Set-AgentsOutput (Get-InteractiveEntry 'idle')
        { Resume-ClaudeInTab $stoppedSession } | Should -Throw '*already running*'
        Should -Invoke Open-ClaudeTab -ModuleName ClaudeSessions -Times 0
    }

    It 'refuses a session a claude process names, from any shell' {
        Mock Get-Process -ModuleName ClaudeSessions { [pscustomobject]@{ ProcessName = 'claude'; CommandLine = "claude.exe -p --resume $sessionId" } }
        { Resume-ClaudeInTab $stoppedSession } | Should -Throw '*starting, or writing a handover*'
        Should -Invoke Open-ClaudeTab -ModuleName ClaudeSessions -Times 0
    }

    It 'refuses a second resume while the first tab is starting' {
        Resume-ClaudeInTab $stoppedSession
        { Resume-ClaudeInTab $stoppedSession } | Should -Throw '*still starting*'
        Should -Invoke Open-ClaudeTab -ModuleName ClaudeSessions -Times 1 -Exactly
    }

    It 'allows a resume right after a stop' {
        Mock Stop-Process -ModuleName ClaudeSessions -RemoveParameterType InputObject { }
        Resume-ClaudeInTab $stoppedSession

        Set-AgentsOutput (Get-InteractiveEntry 'idle')
        Mock Get-Process -ModuleName ClaudeSessions -ParameterFilter { $Id } { [pscustomobject]@{ ProcessName = 'claude'; StartTime = $startedAt } }
        Stop-ClaudeSession $runningSession

        Set-AgentsOutput '[]'
        Resume-ClaudeInTab $stoppedSession
        Should -Invoke Open-ClaudeTab -ModuleName ClaudeSessions -Times 2 -Exactly
    }
}

Describe 'Get-ClaudeTranscriptInfo' {
    It 'finds a title and context that sit before the last 256 KB' {
        $filler = '{"type":"user","message":{"content":"' + ('x' * 1000) + '"}}'
        $lines = @(
            '{"type":"custom-title","customTitle":"Old title"}'
            '{"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":20000,"cache_creation_input_tokens":3000}}}'
        ) + @(1..600 | ForEach-Object { $filler }) + @('{"type":"last-prompt","lastPrompt":"latest"}')
        [IO.File]::WriteAllLines("$TestDrive\transcript.jsonl", $lines)
        Mock Get-Item -ModuleName ClaudeSessions { Microsoft.PowerShell.Management\Get-Item -LiteralPath "$TestDrive\transcript.jsonl" }

        $info = Get-ClaudeTranscriptInfo $sessionId

        $info.customTitle | Should -Be 'Old title'
        $info.contextTokens | Should -Be 24000
        $info.lastPrompt | Should -Be 'latest'
    }
}
