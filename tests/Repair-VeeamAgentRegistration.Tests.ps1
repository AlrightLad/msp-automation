#Requires -Version 5.1
<#
    Pester tests for backup-veeam/Repair-VeeamAgentRegistration.ps1

    The script is never executed: it uninstalls software and can schedule a
    reboot. The registry-reading helpers are lifted out of the AST and tested
    against mocked providers, and the RMM-safety contract is asserted
    structurally. Pester 5.x and 6.x.
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\backup-veeam\Repair-VeeamAgentRegistration.ps1')).Path
    $script:Content    = Get-Content -LiteralPath $script:ScriptPath -Raw
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors)
    $script:ParseErrors = @($errors)

    foreach ($fn in 'Get-VeeamAgentEntries', 'Test-RebootPending') {
        $node = $script:Ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn
            }, $true) | Select-Object -First 1
        if (-not $node) { throw "$fn not found in script" }
        . ([scriptblock]::Create($node.Extent.Text))
    }
    # Script-scope constant the helper reads.
    $script:UninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
}

Describe 'RMM-safety contract' {
    It 'parses without syntax errors' {
        $script:ParseErrors.Count | Should -Be 0 -Because (($script:ParseErrors | ForEach-Object { $_.Message }) -join '; ')
    }
    It 'has comment-based help with a synopsis and notes' {
        $help = $script:Ast.GetHelpContent()
        $help          | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Notes    | Should -Match 'allowReboot'
        $help.Notes    | Should -Match 'orgName'
    }
    It 'declares PowerShell 5.1 as the minimum' {
        $script:Content | Should -Match '#Requires\s+-Version\s+5\.1'
    }
    It 'contains no Read-Host and no switch parameters' {
        $script:Content | Should -Not -Match '\bRead-Host\b'
        @($script:Ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.StaticType.Name -eq 'SwitchParameter'
                }, $true)).Count | Should -Be 0
    }
    It 'takes a single-instance mutex and survives an abandoned one' {
        $script:Content | Should -Match 'System\.Threading\.Mutex'
        $script:Content | Should -Match 'AbandonedMutexException'
        $script:Content | Should -Match 'ReleaseMutex'
    }
    It 'writes a transcript and rotates by retention count' {
        $script:Content | Should -Match '\bStart-Transcript\b'
        $script:Content | Should -Match 'Select-Object -Skip \$Retention'
    }
    It 'relaunches 64-bit from a 32-bit host' {
        $script:Content | Should -Match 'PROCESSOR_ARCHITEW6432'
        $script:Content | Should -Match 'SysNative'
    }
    It 'uses only exit codes 0, 1 and 2' {
        $exits = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        $exits.Count | Should -BeGreaterThan 0
        foreach ($e in $exits) {
            $expr = $e.Pipeline.Extent.Text.Trim()
            if ($expr -match '^\d+$') { [int]$expr | Should -BeIn @(0, 1, 2) -Because "exit $expr at line $($e.Extent.StartLineNumber)" }
        }
    }
    It 'never reboots in report mode' {
        # Every shutdown.exe call sits below the report-mode exits.
        $firstShutdown = $script:Content.IndexOf('shutdown.exe')
        $reportExit    = $script:Content.IndexOf("if (`$Mode -eq 'report') {")
        $firstShutdown | Should -BeGreaterThan $reportExit
    }
    It 'carries no organisation, host or ticket identifiers' {
        $script:Content | Should -Not -Match 'DTC|HALO|\d{7}|BookStack'
    }
}

Describe 'Get-VeeamAgentEntries' {
    Context 'registry holds a Veeam Agent beside unrelated products' {
        BeforeAll {
            Mock Get-ItemProperty {
                [pscustomobject]@{ DisplayName = 'Veeam Agent for Microsoft Windows'; DisplayVersion = '6.0.0.960'; PSChildName = '{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}'; UninstallString = 'MsiExec.exe /X{1111}'; QuietUninstallString = $null; PSPath = 'HKLM:\x\{1111}' }
                [pscustomobject]@{ DisplayName = 'Some Other Product';               DisplayVersion = '1.0';       PSChildName = '{AAAA}'; UninstallString = 'x'; QuietUninstallString = $null; PSPath = 'HKLM:\x\{AAAA}' }
                [pscustomobject]@{ DisplayName = $null;                              DisplayVersion = $null;       PSChildName = '{BBBB}'; UninstallString = $null; QuietUninstallString = $null; PSPath = 'HKLM:\x\{BBBB}' }
            }
        }
        It 'returns only the Veeam Agent entry (happy path)' {
            $e = @(Get-VeeamAgentEntries)
            $e.Count          | Should -Be 1
            $e[0].DisplayName | Should -Be 'Veeam Agent for Microsoft Windows'
            $e[0].ProductCode | Should -Be '{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}'
            $e[0].KeyPath     | Should -Be 'HKLM:\x\{1111}'
        }
        It 'reads both uninstall hives' {
            $null = Get-VeeamAgentEntries
            Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { @($Path).Count -eq 2 }
        }
    }
    Context 'no agent registered (failure path)' {
        BeforeAll { Mock Get-ItemProperty { } }
        It 'returns an empty array, not null' {
            $e = Get-VeeamAgentEntries
            @($e).Count | Should -Be 0
        }
    }
}

Describe 'Test-RebootPending' {
    It 'is true when a reboot-pending key exists' {
        Mock Test-Path { $true }
        Test-RebootPending | Should -BeTrue
    }
    It 'is true when PendingFileRenameOperations is set' {
        Mock Test-Path { $false }
        Mock Get-ItemProperty { [pscustomobject]@{ PendingFileRenameOperations = @('\??\C:\x.tmp', '') } }
        Test-RebootPending | Should -BeTrue
    }
    It 'is false when nothing is pending (failure path of the detection)' {
        Mock Test-Path { $false }
        Mock Get-ItemProperty { $null }
        Test-RebootPending | Should -BeFalse
    }
}
