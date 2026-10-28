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

Describe 'Split-ClaudeSearchMatchText' {
    BeforeAll {
        # Bold runs in angle brackets, so one string shows where each run starts and ends.
        function Format-Runs($Runs)
            { ($Runs | ForEach-Object { $_.isBold ? "<$($_.text)>" : $_.text }) -join '' }
    }

    It 'bolds <Name>' -ForEach @(
        @{ Name = 'every match of every term'; Query = 'timeout retry'; Text = 'Timeout on retry, then another timeout'; Expected = '<Timeout> on <retry>, then another <timeout>' }
        @{ Name = 'a quoted phrase across collapsed spaces'; Query = '"connection refused"'; Text = 'Got connection refused twice'; Expected = 'Got <connection refused> twice' }
        @{ Name = 'a term at a capital inside a code name'; Query = 'notifier'; Text = 'EtlRunNotifier failed'; Expected = 'EtlRun<Notifier> failed' }
        @{ Name = 'overlapping terms as one run'; Query = 'part partition'; Text = 'partition key'; Expected = '<partition> key' }
        @{ Name = 'nothing inside a word'; Query = 'rent'; Text = 'current rent'; Expected = 'current <rent>' }
    ) {
        Format-Runs (Split-ClaudeSearchMatchText $Text $Query) | Should -Be $Expected
    }

    It 'returns nothing for empty text' {
        Split-ClaudeSearchMatchText '' 'timeout' | Should -BeNullOrEmpty
    }
}
