# Compiles the window's native helper from the script itself and checks which queued messages it drops.
BeforeAll {
    Add-Type -AssemblyName System.Windows.Forms

    $windowScript = [IO.File]::ReadAllText("$PSScriptRoot\..\ClaudeSessions\ClaudeSessionsWindow.ps1")
    $definition = [regex]::Match($windowScript, "(?s)-Name Native -MemberDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    Add-Type -Namespace ClaudeSessionsWindowTest -Name Native -MemberDefinition $definition

    Add-Type -Namespace ClaudeSessionsWindowTest -Name Queue -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct Message { public IntPtr Window; public uint Id; public IntPtr WParam; public IntPtr LParam; public uint Time; public int X; public int Y; public uint Private; }
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint id, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool PeekMessage(out Message message, IntPtr window, uint firstId, uint lastId, uint remove);
'@
}

Describe 'DiscardQueuedInput' {
    BeforeAll {
        $form = [System.Windows.Forms.Form]::new()
    }

    AfterAll {
        $form.Dispose()
    }

    It 'matches the size of the Windows MSG structure' {
        [Runtime.InteropServices.Marshal]::SizeOf([type][ClaudeSessionsWindowTest.Native+Message]) | Should -Be 48
    }

    It 'leaves <Name> queued: <Kept>' -ForEach @(
        @{ Name = 'a left click'; Id = 0x0201; Kept = $false }
        @{ Name = 'a key press'; Id = 0x0100; Kept = $false }
        @{ Name = 'a close button click'; Id = 0x00A1; Kept = $false }
        @{ Name = 'an application message'; Id = 0x8001; Kept = $true }
    ) {
        [ClaudeSessionsWindowTest.Queue]::PostMessage($form.Handle, [uint32]$Id, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        [ClaudeSessionsWindowTest.Native]::DiscardQueuedInput()

        $message = [ClaudeSessionsWindowTest.Queue+Message]::new()
        [ClaudeSessionsWindowTest.Queue]::PeekMessage([ref]$message, $form.Handle, [uint32]$Id, [uint32]$Id, 1) | Should -Be $Kept
    }
}
