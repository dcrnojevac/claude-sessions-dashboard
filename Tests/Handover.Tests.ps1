BeforeAll {
    Import-Module "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.psm1" -Force

    $sessionId = '11111111-2222-3333-4444-555555555555'
    $stoppedSession = [pscustomobject]@{ sessionId = $sessionId; title = 'Fake'; cwd = $TestDrive; running = $false }

    function Set-HandoverReply([string]$Json)
    {
        Mock Invoke-ClaudeCommand -ModuleName ClaudeSessions -ParameterFilter { $ClaudeArguments[0] -eq '-p' } -MockWith ([scriptblock]::Create("@'`n$Json`n'@"))
    }
}

Describe 'Get-ClaudeHandoverTitle' {
    It 'continues <Title> as <Expected>' -ForEach @(
        @{ Title = 'Title'; Expected = 'Title (2)' }
        @{ Title = 'Title (2)'; Expected = 'Title (3)' }
        @{ Title = 'Title (9)'; Expected = 'Title (10)' }
        @{ Title = 'Fix (v2)'; Expected = 'Fix (v2) (2)' }
    ) {
        Get-ClaudeHandoverTitle $Title | Should -Be $Expected
    }
}

Describe 'Invoke-ClaudeHandover' {
    BeforeEach {
        Mock Invoke-ClaudeCommand -ModuleName ClaudeSessions -ParameterFilter { $ClaudeArguments[0] -eq 'agents' } { '[]' }
        Mock Get-Process -ModuleName ClaudeSessions { }
        Mock Save-ClaudeFile -ModuleName ClaudeSessions { }
        Mock Open-ClaudeTab -ModuleName ClaudeSessions { }
        Mock Add-ClaudePin -ModuleName ClaudeSessions { }
        Mock Wait-ClaudeSession -ModuleName ClaudeSessions { $true }
    }

    It 'pins the new session in place of the old one once it is running' {
        Set-HandoverReply "{`"type`":`"result`",`"is_error`":false,`"result`":`"# Doc`",`"session_id`":`"$sessionId`"}"

        $handover = Invoke-ClaudeHandover $stoppedSession

        $handover.title | Should -Be 'Fake (2)'
        Should -Invoke Add-ClaudePin -ModuleName ClaudeSessions -ParameterFilter { $ReplacedSessionId -eq $sessionId } -Times 1 -Exactly
    }

    It 'changes nothing when a claude process already names the session' {
        Mock Get-Process -ModuleName ClaudeSessions { [pscustomobject]@{ ProcessName = 'claude'; CommandLine = "claude.exe --resume $sessionId" } }
        { Invoke-ClaudeHandover $stoppedSession } | Should -Throw '*starting, or writing a handover*'
        Should -Invoke Invoke-ClaudeCommand -ModuleName ClaudeSessions -ParameterFilter { $ClaudeArguments[0] -eq '-p' } -Times 0
    }

    It 'changes nothing when another session answers' {
        Set-HandoverReply "{`"type`":`"result`",`"is_error`":false,`"result`":`"# Doc`",`"session_id`":`"99999999-2222-3333-4444-555555555555`"}"
        { Invoke-ClaudeHandover $stoppedSession } | Should -Throw '*not the resumed one*'
        Should -Invoke Save-ClaudeFile -ModuleName ClaudeSessions -Times 0
        Should -Invoke Add-ClaudePin -ModuleName ClaudeSessions -Times 0
    }

    It 'changes nothing when the handover is empty' {
        Set-HandoverReply "{`"type`":`"result`",`"is_error`":false,`"result`":`"  `",`"session_id`":`"$sessionId`"}"
        { Invoke-ClaudeHandover $stoppedSession } | Should -Throw '*no handover*'
        Should -Invoke Add-ClaudePin -ModuleName ClaudeSessions -Times 0
    }

    It 'leaves the pins alone when the new session never appears' {
        Set-HandoverReply "{`"type`":`"result`",`"is_error`":false,`"result`":`"# Doc`",`"session_id`":`"$sessionId`"}"
        Mock Wait-ClaudeSession -ModuleName ClaudeSessions { $false }
        { Invoke-ClaudeHandover $stoppedSession } | Should -Throw '*did not show up*'
        Should -Invoke Open-ClaudeTab -ModuleName ClaudeSessions -Times 1 -Exactly
        Should -Invoke Add-ClaudePin -ModuleName ClaudeSessions -Times 0
    }
}
