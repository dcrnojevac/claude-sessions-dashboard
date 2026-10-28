BeforeAll {
    Import-Module "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.psm1" -Force

    $baselineLine = '- [invoice-ai-benchmark-baseline] Invoice AI benchmark baseline: one full benchmark run on the current model. Trigger: the model upgrade gets scheduled. Added 2026-10-27, parked 2026-10-27.'
    $upgradeLine = '- [invoice-ai-model-upgrade] Invoice AI model upgrade off the current model. After: [invoice-ai-benchmark-baseline]. Trigger: upgrade scheduled. Added 2026-10-27, parked 2026-10-27.'
    $needsReviewLine = '- [invoice-ai-needs-review] Invoice AI "needs review" hold before posting. After: tag-app PR #233 merged. → items/invoice-ai-needs-review.md. Added 2026-10-27, parked 2026-10-27.'

    function New-Tracker([string]$Index, [string]$Archive)
    {
        $path = Join-Path $TestDrive "tracker-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Force (Join-Path $path 'items') | Out-Null
        Set-Content -LiteralPath (Join-Path $path 'TRACKER.md') $Index -Encoding utf8

        if ($Archive)
            { Set-Content -LiteralPath (Join-Path $path 'archive.md') $Archive -Encoding utf8 }

        $path
    }
}

Describe 'ConvertFrom-ClaudeTrackerLine' {
    It 'reads an item with a trigger and no After' {
        $item = ConvertFrom-ClaudeTrackerLine $baselineLine 'Planned'

        $item.id | Should -Be 'invoice-ai-benchmark-baseline'
        $item.title | Should -Be 'Invoice AI benchmark baseline: one full benchmark run on the current model'
        $item.trigger | Should -Be 'the model upgrade gets scheduled'
        $item.after | Should -BeNullOrEmpty
        $item.section | Should -Be 'Planned'
        @($item.stamps.text) | Should -Be @('Added 2026-10-27', 'parked 2026-10-27')
        $item.latestStamp.event | Should -Be 'parked'
        $item.latestStamp.date | Should -Be ([datetime]'2026-10-27')
        $item.outcome | Should -BeNullOrEmpty
    }

    It 'reads an After link to another item' {
        $item = ConvertFrom-ClaudeTrackerLine $upgradeLine 'Planned'

        $item.title | Should -Be 'Invoice AI model upgrade off the current model'
        $item.after.id | Should -Be 'invoice-ai-benchmark-baseline'
        $item.after.event | Should -BeNullOrEmpty
        $item.trigger | Should -Be 'upgrade scheduled'
    }

    It 'reads an After on an outside event and the details link' {
        $item = ConvertFrom-ClaudeTrackerLine $needsReviewLine 'Planned'

        $item.title | Should -Be 'Invoice AI "needs review" hold before posting'
        $item.after.id | Should -BeNullOrEmpty
        $item.after.event | Should -Be 'tag-app PR #233 merged'
        $item.after.state | Should -Be 'event'
        $item.detailsLink | Should -Be 'items/invoice-ai-needs-review.md'
        $item.latestStamp.text | Should -Be 'parked 2026-10-27'
    }

    It 'reads several After ids, a repeated After and an event mixed with ids' {
        $line = '- [release-notes] Release notes. After: [api-docs], [changelog-tool]. After: [qa-pass] and the vendor ships 5.0. Added 2026-01-05.'
        $item = ConvertFrom-ClaudeTrackerLine $line 'Next'

        @($item.after.id | Where-Object { $_ }) | Should -Be @('api-docs', 'changelog-tool', 'qa-pass')
        @($item.after.event | Where-Object { $_ }) | Should -Be @('the vendor ships 5.0')
    }

    It 'reads the repo, wherever its clause sits' {
        $line = '- [rate-limits] Rate limits on the public API. After: [usage-metrics]. Repo: public-api. Trigger: next sprint. Added 2026-01-05.'
        $item = ConvertFrom-ClaudeTrackerLine $line 'Next'

        $item.repo | Should -Be 'public-api'
        $item.title | Should -Be 'Rate limits on the public API'
        $item.after.id | Should -Be 'usage-metrics'
        $item.trigger | Should -Be 'next sprint'
        (ConvertFrom-ClaudeTrackerLine $baselineLine 'Planned').repo | Should -BeNullOrEmpty
    }

    It 'keeps keywords inside `code` and arrows outside items/ in the title' {
        $line = '- [graph-view] Draw `After:` links as a tree, A -> B. Added 2026-01-05.'
        $item = ConvertFrom-ClaudeTrackerLine $line 'Next'

        $item.title | Should -Be 'Draw `After:` links as a tree, A -> B'
        $item.after | Should -BeNullOrEmpty
    }

    It 'reads an archived line with its outcome after the history' {
        $line = '- [api-docs] API reference docs. Added 2026-01-05, started 2026-01-08, archived 2026-01-20. Published; the auth section still needs examples.'
        $item = ConvertFrom-ClaudeTrackerLine $line 'Archive'

        $item.latestStamp.text | Should -Be 'archived 2026-01-20'
        $item.outcome | Should -Be 'Published; the auth section still needs examples.'
        $item.title | Should -Be 'API reference docs'
    }

    It 'keeps a stamp with several words' {
        $item = ConvertFrom-ClaudeTrackerLine '- [cleanup] Cleanup. Added 2026-01-05, moved to Low Priority 2026-02-01.' 'Low Priority'

        $item.latestStamp.event | Should -Be 'moved to Low Priority'
    }

    It 'returns <Case> as raw text' -ForEach @(
        @{ Case = 'a bullet without an id'; Line = '- no id here. Added 2026-10-27.' }
        @{ Case = 'an id that is not kebab-case'; Line = '- [Bad_Id] Title. Added 2026-10-27.' }
        @{ Case = 'an unclosed id'; Line = '- [half-open Title. Added 2026-10-27.' }
        @{ Case = 'a line without a bullet'; Line = '[lost-bullet] Title. Added 2026-10-27.' }
        @{ Case = 'an empty bullet'; Line = '- ' }
    ) {
        $item = ConvertFrom-ClaudeTrackerLine $Line 'Next'

        $item.id | Should -BeNullOrEmpty
        $item.raw | Should -Be $Line.Trim()
        $item.section | Should -Be 'Next'
    }

    It 'reads an item without any history' {
        $item = ConvertFrom-ClaudeTrackerLine '- [no-history] Just a title' 'Next'

        $item.id | Should -Be 'no-history'
        $item.title | Should -Be 'Just a title'
        $item.stamps | Should -BeNullOrEmpty
        $item.latestStamp | Should -BeNullOrEmpty
    }

    It 'keeps a stamp whose date does not exist, without a date' {
        $item = ConvertFrom-ClaudeTrackerLine '- [bad-date] Title. Added 2026-13-45.' 'Next'

        $item.latestStamp.text | Should -Be 'Added 2026-13-45'
        $item.latestStamp.date | Should -BeNullOrEmpty
    }

    It 'ignores a details link that leaves the items folder' {
        $item = ConvertFrom-ClaudeTrackerLine '- [escape] Title. → items/../../secrets.md. Added 2026-01-05.' 'Next'

        $item.detailsLink | Should -BeNullOrEmpty
    }
}

Describe 'Get-ClaudeTracker' {
    It 'returns no items and no error when <Case>' -ForEach @(
        @{ Case = 'the folder does not exist'; Make = { Join-Path $TestDrive 'no-tracker-here' } }
        @{ Case = 'the folder has no TRACKER.md'; Make = { $path = Join-Path $TestDrive 'empty-tracker'; New-Item -ItemType Directory -Force $path | Out-Null; $path } }
        @{ Case = 'no folder is given'; Make = { '' } }
    ) {
        $path = & $Make

        { Get-ClaudeTracker $path } | Should -Not -Throw
        $tracker = Get-ClaudeTracker $path
        $tracker.isSetUp | Should -BeFalse
        $tracker.items | Should -BeNullOrEmpty
        $tracker.archivedItems | Should -BeNullOrEmpty
    }

    Context 'with a tracker' {
        BeforeAll {
            $index = @(
                '# Tracker'
                ''
                '## In Progress'
                ''
                '- [api-usage-metrics] Usage metrics per API key. Added 2026-01-05, started 2026-01-08.'
                ''
                '## Next'
                ''
                '- [rate-limits] Rate limits on the public API. After: [api-usage-metrics]. Added 2026-01-05.'
                '- [release-notes] Release notes. After: [api-docs]. Added 2026-01-05.'
                '- [mystery] Depends on a typo. After: [no-such-item]. Added 2026-01-05.'
                'a stray line that lost its bullet'
                ''
                '## Planned'
                ''
                $baselineLine
                $upgradeLine
                $needsReviewLine
                '- [Broken line without a proper id'
                ''
                '## Low Priority'
                ''
                '- [tidy-scripts] Tidy the build scripts. Added 2026-01-05, moved to Low Priority 2026-01-09.'
            ) -join "`n"
            $archive = @(
                '# Tracker archive'
                ''
                'Finished items, one line each.'
                ''
                '- [api-docs] API reference docs. Added 2026-01-05, archived 2026-01-20. Published.'
                '- [docs-review] Review of the API docs. After: [api-docs]. Added 2026-01-06, archived 2026-01-21. Done.'
            ) -join "`n"

            $path = New-Tracker $index $archive
            Set-Content -LiteralPath (Join-Path $path 'items\invoice-ai-needs-review.md') '# Details' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $path 'items\tidy-scripts.md') '# Unlinked details' -Encoding utf8
            $tracker = Get-ClaudeTracker $path
            $items = @{}

            foreach ($item in $tracker.items | Where-Object id)
                { $items[$item.id] = $item }
        }

        It 'reads every item into its section, in file order' {
            $tracker.isSetUp | Should -BeTrue
            @($tracker.items | ForEach-Object { "$($_.section):$($_.id)" }) | Should -Be @(
                'In Progress:api-usage-metrics'
                'Next:rate-limits'
                'Next:release-notes'
                'Next:mystery'
                'Next:'
                'Planned:invoice-ai-benchmark-baseline'
                'Planned:invoice-ai-model-upgrade'
                'Planned:invoice-ai-needs-review'
                'Planned:'
                'Low Priority:tidy-scripts'
            )
        }

        It 'keeps malformed lines as raw text in their section' {
            @($tracker.items | Where-Object { -not $_.id } | ForEach-Object raw) | Should -Be @(
                'a stray line that lost its bullet'
                '- [Broken line without a proper id'
            )
        }

        It 'skips the archive intro and reads its items' {
            @($tracker.archivedItems.id) | Should -Be @('api-docs', 'docs-review')
            $tracker.archivedItems[0].outcome | Should -Be 'Published.'
        }

        It 'resolves the After links of archived items too' {
            $tracker.archivedItems[1].after[0].state | Should -Be 'archived'
        }

        It 'marks <Id> as <State>' -ForEach @(
            @{ Id = 'rate-limits'; State = 'blocked'; LinkState = 'open' }
            @{ Id = 'invoice-ai-model-upgrade'; State = 'blocked'; LinkState = 'open' }
            @{ Id = 'release-notes'; State = 'unblocked'; LinkState = 'archived' }
            @{ Id = 'mystery'; State = 'unknown'; LinkState = 'missing' }
            @{ Id = 'invoice-ai-needs-review'; State = 'waiting'; LinkState = 'event' }
        ) {
            $items[$Id].afterState | Should -Be $State
            $items[$Id].after[0].state | Should -Be $LinkState
        }

        It 'leaves items without After unmarked' {
            $items['api-usage-metrics'].afterState | Should -BeNullOrEmpty
        }

        It 'finds details files linked or not, and only when they exist' {
            $items['invoice-ai-needs-review'].detailsPath | Should -Be (Join-Path $path 'items/invoice-ai-needs-review.md')
            $items['tidy-scripts'].detailsPath | Should -Be (Join-Path $path 'items/tidy-scripts.md')
            $items['rate-limits'].detailsPath | Should -BeNullOrEmpty
        }
    }

    It 'reads a tracker without archive.md' {
        $path = New-Tracker "## Next`n`n$upgradeLine"
        $tracker = Get-ClaudeTracker $path

        $tracker.archivedItems | Should -BeNullOrEmpty
        $tracker.items[0].afterState | Should -Be 'unknown'
    }

    It 'reads a file a session holds open for writing' {
        $path = New-Tracker "## Next`n`n$baselineLine"
        $writer = [IO.File]::Open((Join-Path $path 'TRACKER.md'), 'Open', 'ReadWrite', 'ReadWrite')

        try
        {
            (Get-ClaudeTracker $path).items[0].id | Should -Be 'invoice-ai-benchmark-baseline'
        }
        finally
        {
            $writer.Dispose()
        }
    }
}

Describe 'Get-ClaudeTrackerPath' {
    It 'uses trackerPath from the settings' {
        Get-ClaudeTrackerPath ([pscustomobject]@{ trackerPath = 'D:\notes\tracker' }) | Should -Be 'D:\notes\tracker'
    }

    It 'defaults to the tracker folder in ~\.claude' {
        Get-ClaudeTrackerPath ([pscustomobject]@{ reposRoot = 'C:\src' }) | Should -Be (Join-Path $HOME '.claude\tracker')
    }
}

Describe 'Format-ClaudeDaysSince' {
    It 'says <Expected> for <Days> days ago' -ForEach @(
        @{ Days = 0; Expected = 'today' }
        @{ Days = 1; Expected = '1 day' }
        @{ Days = 12; Expected = '12 days' }
    ) {
        Format-ClaudeDaysSince (Get-Date).Date.AddDays(-$Days) | Should -Be $Expected
    }
}

Describe 'Split-ClaudeTrackerBoldText' {
    BeforeAll {
        # Bold runs in angle brackets, so one string shows where each run starts and ends.
        function Format-Runs($Runs)
            { ($Runs | ForEach-Object { $_.isBold ? "<$($_.text)>" : $_.text }) -join '' }
    }

    It 'bolds <Name>' -ForEach @(
        @{ Name = 'text between double asterisks, without them'; Text = 'Keep **the order** as is'; Expected = 'Keep <the order> as is' }
        @{ Name = 'a known id, with its brackets'; Text = 'After: [invoice-ai-model-upgrade].'; Expected = 'After: <[invoice-ai-model-upgrade]>.' }
        @{ Name = 'several runs on several lines'; Text = "**One**`n- [invoice-ai-model-upgrade] and **two**"; Expected = "<One>`n- <[invoice-ai-model-upgrade]> and <two>" }
    ) {
        Format-Runs (Split-ClaudeTrackerBoldText $Text @('invoice-ai-model-upgrade')) | Should -Be $Expected
    }

    It 'leaves <Name> plain' -ForEach @(
        @{ Name = 'an id the tracker does not know'; Text = 'Writes to [etl].[KeyChange]' }
        @{ Name = 'asterisks in a code span'; Text = 'Call `f(**a, **b)` here' }
        @{ Name = 'a known id in a code span'; Text = 'See `[invoice-ai-model-upgrade]`' }
        @{ Name = 'a fenced block'; Text = "``````python`nf(**a, **b)`n``````" }
        @{ Name = 'asterisks that do not close on the same line'; Text = "**open`nclose**" }
        @{ Name = 'asterisks around a space'; Text = 'a ** b ** c' }
    ) {
        Format-Runs (Split-ClaudeTrackerBoldText $Text @('invoice-ai-model-upgrade')) | Should -Be $Text
    }

    It 'returns nothing for empty text' {
        Split-ClaudeTrackerBoldText '' @() | Should -BeNullOrEmpty
    }
}
