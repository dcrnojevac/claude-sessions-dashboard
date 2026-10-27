# Every path points into Pester's temporary drive; nothing of your real install, profile or Start menu is touched.
BeforeAll {
    . "$PSScriptRoot\..\Install.ps1"

    $source = Join-Path $TestDrive 'repo\ClaudeSessions'
    New-Item -ItemType Directory -Force (Join-Path $source 'Sub') | Out-Null
    Set-Content (Join-Path $source 'ClaudeSessions.psm1') '# module'
    Set-Content (Join-Path $source 'ClaudeSessionsWindow.ps1') '# window'
    Set-Content (Join-Path $source 'Sub\Part.ps1') '# part'
    Copy-Item "$PSScriptRoot\..\ClaudeSessions\ClaudeSessions.ico" $source
}

Describe 'Install-ModuleFolder' {
    BeforeEach {
        $target = Join-Path $TestDrive "modules-$([guid]::NewGuid().ToString('N'))\ClaudeSessions"
    }

    It 'copies every file of the module' {
        Install-ModuleFolder $source $target

        Get-ChildItem $target -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($target, $_.FullName) } | Sort-Object |
            Should -Be @('ClaudeSessions.ico', 'ClaudeSessions.psm1', 'ClaudeSessionsWindow.ps1', 'Sub\Part.ps1')
    }

    It 'keeps and reports files an update does not ship' {
        New-Item -ItemType Directory -Force $target | Out-Null
        Set-Content (Join-Path $target 'Old notes.md') 'mine'

        Get-UnknownModuleFile $source $target | Should -Be 'Old notes.md'
        Install-ModuleFolder $source $target
        Join-Path $target 'Old notes.md' | Should -Exist
    }

    It 'links the module folder to the repo' {
        Install-ModuleFolder $source $target -Link

        (Get-Item $target).LinkType | Should -Be 'Junction'
        Join-Path $target 'Sub\Part.ps1' | Should -Exist
    }

    It 'replaces a link with a copy and leaves the repo alone' {
        Install-ModuleFolder $source $target -Link
        Install-ModuleFolder $source $target

        (Get-Item $target).LinkType | Should -BeNullOrEmpty
        Join-Path $target 'ClaudeSessions.psm1' | Should -Exist
        Join-Path $source 'ClaudeSessions.psm1' | Should -Exist
    }

    It 'sends a copy to the Recycle Bin when replacing it with a link' {
        Mock Remove-ToRecycleBin { Remove-Item -LiteralPath $Path -Recurse -Force }
        Install-ModuleFolder $source $target

        Install-ModuleFolder $source $target -Link

        Should -Invoke Remove-ToRecycleBin -ParameterFilter { $Path -eq $target } -Times 1 -Exactly
        (Get-Item $target).LinkType | Should -Be 'Junction'
    }
}

Describe 'Remove-ModuleLink' {
    It 'removes the link and leaves every file of the repo' {
        $target = Join-Path $TestDrive 'linked\ClaudeSessions'
        Install-ModuleFolder $source $target -Link

        Remove-ModuleLink $target

        $target | Should -Not -Exist
        @(Get-ChildItem $source -File -Recurse).Count | Should -Be 4
    }
}

Describe 'Profile line' {
    BeforeEach {
        $profilePath = Join-Path $TestDrive "profile-$([guid]::NewGuid().ToString('N')).ps1"
    }

    It 'is added once to a new profile' {
        Add-ProfileLine $profilePath
        Add-ProfileLine $profilePath

        @(Get-Content $profilePath) | Should -Be @('Import-Module ClaudeSessions')
    }

    It 'is added after what a profile already has' {
        Set-Content $profilePath 'Set-Alias g git' -NoNewline
        Add-ProfileLine $profilePath

        @(Get-Content $profilePath) | Should -Be @('Set-Alias g git', 'Import-Module ClaudeSessions')
    }

    It 'is removed without touching the rest of the profile' {
        Set-Content $profilePath @('Set-Alias g git', 'Import-Module ClaudeSessions', '$env:EDITOR = ''code''')
        Remove-ProfileLine $profilePath

        @(Get-Content $profilePath) | Should -Be @('Set-Alias g git', '$env:EDITOR = ''code''')
    }
}

Describe 'Assert-DefaultRepo' {
    BeforeAll {
        $reposRoot = Join-Path $TestDrive 'repos'
        New-Item -ItemType Directory -Force (Join-Path $reposRoot 'web-shop'), (Join-Path $reposRoot 'billing-api'), (Join-Path $reposRoot 'clients\portal') | Out-Null
    }

    It 'accepts <Case>' -ForEach @(
        @{ Case = 'the name of a folder under the repos folder'; Value = 'web-shop' }
        @{ Case = 'the path of a repo in a folder'; Value = 'clients\portal' }
    ) {
        { Assert-DefaultRepo $reposRoot $Value } | Should -Not -Throw
    }

    It 'refuses <Case>, naming the folders that are there' -ForEach @(
        @{ Case = 'a full path'; Value = "$TestDrive\repos\web-shop" }
        @{ Case = 'a path that leaves the repos folder'; Value = '..\repos\web-shop' }
        @{ Case = 'a folder that does not exist'; Value = 'mobile-app' }
        @{ Case = 'nothing'; Value = '' }
    ) {
        { Assert-DefaultRepo $reposRoot $Value } | Should -Throw '*path from there*billing-api, clients, web-shop*'
    }
}

Describe 'New-SettingsFile' {
    It 'writes the repos folder and default repo' {
        $settingsPath = Join-Path $TestDrive 'data\settings.json'
        New-SettingsFile $settingsPath 'C:\src' 'my-repo'

        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $settings.reposRoot | Should -Be 'C:\src'
        $settings.defaultRepo | Should -Be 'my-repo'
    }
}

Describe 'Set-WindowShortcut' {
    It 'starts the window hidden, with its icon and taskbar identity' {
        $shortcutPath = Join-Path $TestDrive 'Start Menu\Claude Sessions.lnk'
        $moduleFolder = Join-Path $TestDrive 'modules\ClaudeSessions'

        Set-WindowShortcut $shortcutPath $moduleFolder

        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
        $shortcut.TargetPath | Should -BeLike '*pwsh.exe'
        $shortcut.Arguments | Should -Be "-NoProfile -STA -WindowStyle Hidden -File `"$moduleFolder\ClaudeSessionsWindow.ps1`""
        $shortcut.IconLocation | Should -Be "$moduleFolder\ClaudeSessions.ico,0"
        [ClaudeSessionsInstall.Shortcut]::GetAppUserModelId($shortcutPath) | Should -Be 'ClaudeSessions.Window'
    }
}
