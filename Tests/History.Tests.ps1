BeforeAll {
    Import-Module "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.psm1" -Force
}

Describe 'Update-ClaudeHistory' {
    It 'leaves the search cache alone when no transcripts are found at all' {
        Mock Read-ClaudeJsonFile -ModuleName ClaudeSessions { @{ 'some-session' = @{ sessionId = 'some-session' } } }
        Mock Get-ChildItem -ModuleName ClaudeSessions { }
        Mock Remove-ClaudeFile -ModuleName ClaudeSessions { }
        Mock Save-ClaudeFile -ModuleName ClaudeSessions { }

        { Update-ClaudeHistory } | Should -Throw '*may have moved them*'
        Should -Invoke Remove-ClaudeFile -ModuleName ClaudeSessions -Times 0
        Should -Invoke Save-ClaudeFile -ModuleName ClaudeSessions -Times 0
    }
}

Describe 'cch' {
    BeforeEach {
        Mock Search-ClaudeHistory -ModuleName ClaudeSessions { }
        Mock Write-Host -ModuleName ClaudeSessions { }
    }

    It 'keeps a quoted phrase together' {
        cch "connection refused" timeout
        Should -Invoke Search-ClaudeHistory -ModuleName ClaudeSessions -ParameterFilter { $Query -eq '"connection refused" timeout' } -Times 1 -Exactly
    }

    It 'passes a phrase typed with literal quotes as typed' {
        cch '"connection refused"'
        Should -Invoke Search-ClaudeHistory -ModuleName ClaudeSessions -ParameterFilter { $Query -eq '"connection refused"' } -Times 1 -Exactly
    }
}
