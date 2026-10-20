# Runs the real Invoke-ClaudeCommand with pwsh standing in for claude.
BeforeAll {
    Import-Module "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.psm1" -Force

    $pwshPath = (Get-Process -Id $PID).Path

    function Invoke-Pwsh([string]$Command, [int]$TimeoutSeconds = 20)
    {
        Invoke-ClaudeCommand '' @('-NoProfile', '-Command', $Command) ([TimeSpan]::FromSeconds($TimeoutSeconds))
    }
}

Describe 'Invoke-ClaudeCommand' {
    BeforeAll {
        Mock Get-Command -ModuleName ClaudeSessions { [pscustomobject]@{ Source = $pwshPath } }
    }

    It 'kills a process past its timeout' {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-Pwsh 'Start-Sleep 30' 2 } | Should -Throw '*did not finish within 2 seconds*'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
        Get-Process pwsh | Where-Object { $_.Parent.Id -eq $PID -and $_.CommandLine -like '*Start-Sleep 30*' } | Should -BeNullOrEmpty
    }

    It 'stops waiting for output that a leftover process keeps open' {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        { Invoke-Pwsh 'cmd /c "start /b ping -n 15 127.0.0.1"' 2 } | Should -Throw '*output was still open*'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }

    It 'reads the output as UTF-8' {
        (Invoke-Pwsh '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); "héllo → ok"').Trim() | Should -Be 'héllo → ok'
    }

    It 'reports a failed exit code' {
        { Invoke-Pwsh 'exit 3' } | Should -Throw '*exit code 3*'
    }

    AfterAll {
        Get-Process ping -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*-n 15 127.0.0.1*' } | Stop-Process
    }
}
