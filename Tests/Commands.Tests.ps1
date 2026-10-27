BeforeAll {
    Import-Module "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.psm1" -Force

    $reposRoot = Join-Path $TestDrive 'repos'

    foreach ($repo in 'web-shop', 'clients\portal', 'clients\api', 'archive\old\web-shop', 'archive\old\api', 'web-shop\nested', '.hidden\tool')
        { New-Item -ItemType Directory -Force (Join-Path $reposRoot "$repo\.git") | Out-Null }

    foreach ($folder in 'notes\drafts', 'clients\docs-site', 'archive\too\deep\repo')
        { New-Item -ItemType Directory -Force (Join-Path $reposRoot $folder) | Out-Null }

    New-Item -ItemType Directory -Force (Join-Path $reposRoot 'clients\billing-api') | Out-Null
    Set-Content (Join-Path $reposRoot 'clients\billing-api\.git') 'gitdir: C:\elsewhere\.git\worktrees\billing-api'
    New-Item -ItemType Directory -Force (Join-Path $reposRoot 'archive\too\deep\repo\.git') | Out-Null

    Mock Get-ClaudeSessionsSetting -ModuleName ClaudeSessions { [pscustomobject]@{ reposRoot = $reposRoot; defaultRepo = 'portal' } }
}

Describe 'Get-ClaudeRepo' {
    It 'lists repos by their path from the root, and top folders without a repo as they are' {
        Get-ClaudeRepo $reposRoot | Should -Be @(
            'archive\old\api'
            'archive\old\web-shop'
            'clients\api'
            'clients\billing-api'
            'clients\portal'
            'notes'
            'web-shop'
        )
    }

    It 'lists every folder of a flat root, as it always did' {
        Get-ClaudeRepo (Join-Path $reposRoot 'clients') | Should -Be @('api', 'billing-api', 'docs-site', 'portal')
    }
}

Describe 'Resolve-ClaudeRepo' {
    It 'resolves <Repo> to <Expected>' -ForEach @(
        @{ Repo = 'portal'; Expected = 'clients\portal' }
        @{ Repo = 'clients\portal'; Expected = 'clients\portal' }
        @{ Repo = 'billing-api'; Expected = 'clients\billing-api' }
        @{ Repo = 'web-shop'; Expected = 'web-shop' }
        @{ Repo = 'notes'; Expected = 'notes' }
    ) {
        Resolve-ClaudeRepo $reposRoot $Repo | Should -Be (Join-Path $reposRoot $Expected)
    }

    It 'refuses a name two repos share, naming both' {
        { Resolve-ClaudeRepo $reposRoot 'api' } | Should -Throw "*2 repos*archive\old\api, clients\api*"
    }

    It 'refuses a repo that is not there' {
        { Resolve-ClaudeRepo $reposRoot 'mobile-app' } | Should -Throw "*no repo 'mobile-app'*"
    }
}

Describe 'acd' {
    It 'goes to the default repo by its name' {
        Push-Location $TestDrive

        try
        {
            acd
            (Get-Location).Path | Should -Be (Join-Path $reposRoot 'clients\portal')
        }
        finally
        {
            Pop-Location
        }
    }

    It 'completes <Typed> to <Expected>' -ForEach @(
        @{ Typed = 'acd por'; Expected = @('portal') }
        @{ Typed = 'acd ap'; Expected = @('archive\old\api', 'clients\api') }
        @{ Typed = 'acd clients\'; Expected = @('clients\api', 'clients\billing-api', 'clients\portal') }
    ) {
        $completions = TabExpansion2 -inputScript $Typed -cursorColumn $Typed.Length

        @($completions.CompletionMatches.CompletionText) | Should -Be $Expected
    }
}
