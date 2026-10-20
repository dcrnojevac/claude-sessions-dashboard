BeforeAll {
    Import-Module "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.psm1" -Force

    InModuleScope ClaudeSessions -Parameters @{ Folder = $TestDrive } {
        param($Folder)

        $script:ClaudePinsPath = Join-Path $Folder 'pins.json'
        $script:ClaudeLabelsPath = Join-Path $Folder 'labels.json'
    }

    function Get-PinnedIds
    {
        @(Get-ClaudePin).sessionId -join ','
    }
}

Describe 'Pins' {
    BeforeEach {
        InModuleScope ClaudeSessions {
            Save-ClaudePin @([pscustomobject]@{ sessionId = 'old'; name = 'Old'; cwd = 'C:\x' }, [pscustomobject]@{ sessionId = 'other'; name = 'Other'; cwd = 'C:\x' })
        }
    }

    It 'swaps the handed-over session for the new one in one change' {
        Add-ClaudePin ([pscustomobject]@{ sessionId = 'new'; name = 'New'; cwd = 'C:\x' }) -ReplacedSessionId 'old'
        Get-PinnedIds | Should -Be 'other,new'
    }

    It 'leaves no temporary files behind' {
        Remove-ClaudePin 'other'
        Get-ChildItem $TestDrive -Filter '*.tmp' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-WithClaudeFileLock' {
    BeforeAll {
        $pwshPath = (Get-Process -Id $PID).Path
        $holdLock = "`$lock = [Threading.Mutex]::new(`$false, 'Local\ClaudeSessionsFiles'); `$lock.WaitOne() | Out-Null; Start-Sleep 15"
    }

    BeforeEach {
        InModuleScope ClaudeSessions { Save-ClaudePin @([pscustomobject]@{ sessionId = 'other'; name = 'Other'; cwd = 'C:\x' }) }
        $holder = Start-Process $pwshPath -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $holdLock
        Start-Sleep -Seconds 2
    }

    AfterEach {
        if (-not $holder.HasExited)
            { $holder.Kill() }

        $holder.WaitForExit()
    }

    It 'makes a change wait for the lock, then give up without writing' {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        { Remove-ClaudePin 'other' } | Should -Throw '*held the pins and labels*'
        $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 9
        Get-PinnedIds | Should -Be 'other'
    }

    It 'takes over a lock left by a killed process' {
        $holder.Kill()
        $holder.WaitForExit()
        Remove-ClaudePin 'other'
        Get-PinnedIds | Should -BeNullOrEmpty
    }
}
