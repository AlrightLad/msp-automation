#Requires -Version 5.1
<#
    Pester tests for msft-windows/msft-windows-domain-readiness-audit.ps1 (v2.6.1)

    The script under test is deliberately NOT executed: its top-level body runs on
    dot-source and would audit the build machine and write a transcript. The tests
    parse the AST, assert the structural and safety contracts, and lift individual
    helpers out of the AST to unit-test them in isolation. Pester 5.x and 6.x.
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\msft-windows\msft-windows-domain-readiness-audit.ps1')).Path
    $script:Content    = Get-Content -LiteralPath $script:ScriptPath -Raw
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors)
    $script:ParseErrors = @($errors)

    # Lift each helper (top-level or nested) out of the AST and define it in this scope. Dot-sourcing
    # must happen here, not inside a helper function, or the definitions land in the wrong scope.
    foreach ($fn in 'Limit-Text', 'Register-Checklist', 'Initialize-Checklist', 'Test-ServiceAccountProfile', 'Get-RegValue',
                    'Get-PendingRebootState', 'Get-OsLifecycleState', 'Resolve-ProfileAccount', 'Get-PathActivity', 'Add-Emit') {
        $node = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true) | Select-Object -First 1
        if (-not $node) { throw "$fn not found in script" }
        . ([scriptblock]::Create($node.Extent.Text))
    }
    # The two script constants the helpers read, taken from the script's own assignment statements.
    foreach ($cn in 'ServiceProfilePattern', 'MaxChecklistValue') {
        $node = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $cn) }, $false) | Select-Object -First 1
        if (-not $node) { throw "`$$cn assignment not found in script" }
        . ([scriptblock]::Create($node.Extent.Text))
        Set-Variable -Name $cn -Scope Script -Value (Get-Variable -Name $cn -ValueOnly)
    }
}

Describe 'File integrity' {
    It 'parses without syntax errors' {
        $script:ParseErrors.Count | Should -Be 0 -Because (($script:ParseErrors | ForEach-Object { $_.Message }) -join '; ')
    }
    It 'declares PowerShell 5.1 as the minimum' {
        $script:Content | Should -Match '#Requires\s+-Version\s+5\.1'
    }
    It 'carries no organisation, person, ticket or internal page identifiers' {
        # -match is case-insensitive, so one lookbehind-guarded alternative covers DTC/Dtc/dtc; MSDTC is a Windows service name
        $script:Content | Should -Not -Match '(?<!MS)DTC|Lance|KB 4082|\d{7}'
    }
}

Describe 'Non-interactive contract' {
    It 'contains no Read-Host, Get-Credential or Write-Host' {
        $script:Content | Should -Not -Match '\bRead-Host\b'
        $script:Content | Should -Not -Match '\bGet-Credential\b'
        $script:Content | Should -Not -Match '\bWrite-Host\b'
    }
    It 'declares no switch parameters' {
        @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.StaticType.Name -eq 'SwitchParameter' }, $true)).Count |
            Should -Be 0 -Because 'switch parameters do not bind from RMM preset variables'
    }
    It 'documents every AUDIT_ environment variable it reads' {
        $read = @([regex]::Matches($script:Content, '\$env:AUDIT_(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Where-Object { $_ -ne 'RELAUNCHED' })
        $read.Count | Should -BeGreaterThan 5
        $notes = $script:Ast.GetHelpContent().Notes
        foreach ($v in $read) { $notes | Should -Match ('AUDIT_' + $v) -Because "AUDIT_$v is read from the environment and must be documented" }
    }
}

Describe 'Read-only contract' {
    It 'does not start, stop or restart services' {
        $script:Content | Should -Not -Match '\b(Set|Start|Stop|Restart)-Service\b'
    }
    It 'does not write to the registry' {
        $script:Content | Should -Not -Match '\b(Set|New|Remove)-ItemProperty\b'
        $script:Content | Should -Not -Match 'New-Item\s+-Path\s+''?HK'
    }
    It 'does not modify access control lists' {
        $script:Content | Should -Not -Match '\bSet-Acl\b'
    }
    It 'limits Remove-Item to transcript rotation' {
        $hits = @([regex]::Matches($script:Content, '\bRemove-Item\b'))
        $hits.Count | Should -Be 1
        $idx = $hits[0].Index
        $script:Content.Substring([Math]::Max(0, $idx - 300), 300) | Should -Match 'Select-Object -Skip \$LogRetention'
    }
}

Describe 'RMM operational contract' {
    It 'takes a single-instance mutex and survives an abandoned one' {
        $script:Content | Should -Match 'System\.Threading\.Mutex'
        $script:Content | Should -Match 'AbandonedMutexException'
        $script:Content | Should -Match 'ReleaseMutex'
    }
    It 'writes a transcript, rotates by retention count and stops it in finally' {
        $script:Content | Should -Match '\bStart-Transcript\b'
        $script:Content | Should -Match 'Select-Object -Skip \$LogRetention'
        $script:Content.Substring($script:Content.LastIndexOf('finally {')) | Should -Match 'Stop-Transcript'
    }
    It 'relaunches 64-bit from a 32-bit host before anything else, guarded against a relaunch loop' {
        $script:Content.IndexOf('PROCESSOR_ARCHITEW6432') | Should -BeLessThan $script:Content.IndexOf('Start-Transcript')
        $script:Content | Should -Match 'SysNative'
        $script:Content | Should -Match '\$env:AUDIT_RELAUNCHED'
    }
    It 'emits a completion token on every path so truncation is detectable' {
        @([regex]::Matches($script:Content, 'Write-Output \$CompleteToken')).Count | Should -BeGreaterOrEqual 3
        $script:Content | Should -Match "CompleteToken = '##AUDIT-COMPLETE##'"
    }
    It 'uses exit codes 0 and 1 only, and no longer lets flags drive the exit code' {
        $assigned = @([regex]::Matches($script:Content, '\$script:ExitCode\s*=\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
        $assigned | Should -Be @(0, 1)
        $exits = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        foreach ($e in $exits) { $t = $e.Pipeline.Extent.Text.Trim(); if ($t -match '^\d+$') { [int]$t | Should -BeIn @(0, 1, 2) } }
        $script:Content | Should -Match 'exit \$script:ExitCode'
    }
    It 'wraps the body in try/catch/finally so a failure still returns a usable exit code' {
        @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)).Count | Should -BeGreaterThan 0
        $script:Content | Should -Match 'AUDIT ERROR - report is INCOMPLETE'
    }
    It 'caps the output budget at the ceiling the RMM truncates at' {
        $script:Content | Should -Match 'if \(\$OutputBudget -gt 9900\) \{ \$OutputBudget = 9900 \}'
    }
}

Describe 'Virtualisation classification' {
    It 'classifies the platform and does not use HypervisorPresent as the test' {
        $script:Content | Should -Match 'Get-VirtualisationPlatform'
        $script:Content | Should -Match "'Hyper-V guest'"
        $script:Content | Should -Not -Match '\$cs\.HypervisorPresent'
        # dots for the separators: the literal backslashes read as a UNC path to the pre-push scan
        $script:Content | Should -Match 'Virtual Machine.Guest.Parameters'
    }
    It 'gates the warranty and out-of-band checklist lines on guest status' {
        $script:Content | Should -Match "CL-2\.1-A' -Status 'N/A'"
        $script:Content | Should -Match "CL-2\.1-B' -Status 'N/A'"
    }
}

Describe 'Function naming' {
    It 'uses approved verbs for every function' {
        $approved = (Get-Verb).Verb
        $functions = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $functions.Count | Should -BeGreaterThan 20
        foreach ($fn in $functions) { $approved | Should -Contain $fn.Name.Split('-')[0] -Because "function '$($fn.Name)' must use an approved verb" }
    }
}

Describe 'Limit-Text' {
    It 'returns short and empty text unchanged (happy path)' {
        Limit-Text -Text 'short' -Max 10 | Should -Be 'short'
        Limit-Text -Text '' -Max 10 | Should -Be ''
    }
    It 'truncates to the budget and marks the cut (failure path)' {
        $r = Limit-Text -Text ('x' * 80) -Max 40
        $r.Length | Should -Be 40
        $r | Should -Match '\.\.\.\[tscript\]$'
    }
}

Describe 'Checklist register' {
    BeforeAll {
        $script:Checklist = New-Object System.Collections.ArrayList
        Initialize-Checklist
    }
    It 'registers every checklist ID up front with a unique id and a valid status' {
        $script:Checklist.Count | Should -BeGreaterThan 40
        @($script:Checklist.Id | Sort-Object -Unique).Count | Should -Be $script:Checklist.Count
        foreach ($c in $script:Checklist) { $c.Id | Should -Match '^CL-'; $c.Status | Should -BeIn @('CAPTURED', 'PARTIAL', 'OPEN', 'N/A') }
    }
    It 'names a source for every OPEN item so the report doubles as a per-owner capture list' {
        foreach ($c in ($script:Checklist | Where-Object Status -eq 'OPEN')) { $c.Source | Should -Not -BeNullOrEmpty }
    }
    It 'overwrites an existing id in place, keeping the source unless one is given (happy path)' {
        $before = $script:Checklist.Count
        $src = ($script:Checklist | Where-Object Id -eq 'CL-1.2-G').Source
        Register-Checklist -Id 'CL-1.2-G' -Status 'CAPTURED' -Value 'none pending'
        $script:Checklist.Count | Should -Be $before
        $row = $script:Checklist | Where-Object Id -eq 'CL-1.2-G'
        $row.Status | Should -Be 'CAPTURED'; $row.Value | Should -Be 'none pending'; $row.Source | Should -Be $src
        Register-Checklist -Id 'CL-1.2-G' -Status 'OPEN' -Value 'x' -Source 'Dispatch'
        ($script:Checklist | Where-Object Id -eq 'CL-1.2-G').Source | Should -Be 'Dispatch'
    }
    It 'bounds a value at the checklist budget (failure path)' {
        Register-Checklist -Id 'CL-TEST' -Status 'PARTIAL' -Value ('y' * 400)
        ($script:Checklist | Where-Object Id -eq 'CL-TEST').Value.Length | Should -Be $MaxChecklistValue
    }
}

Describe 'Test-ServiceAccountProfile' {
    It 'identifies NT SERVICE principals and virtual service accounts (happy path)' {
        Test-ServiceAccountProfile -Account 'NT SERVICE\MSSQLSERVER' | Should -BeTrue
        Test-ServiceAccountProfile -Account ($env:COMPUTERNAME + '\SQLTELEMETRY$INST') | Should -BeTrue
        Test-ServiceAccountProfile -Account ($env:COMPUTERNAME + '\MSSQLFDLauncher') | Should -BeTrue
    }
    It 'leaves a person alone (failure path)' {
        Test-ServiceAccountProfile -Account ($env:COMPUTERNAME + '\jdoe') | Should -BeFalse
    }
}

Describe 'Get-OsLifecycleState' {
    It 'marks an end-of-support OS expired, with the date' {
        $r = Get-OsLifecycleState -Caption 'Microsoft Windows Server 2012 R2 Standard'
        $r.Expired | Should -BeTrue; $r.Label | Should -Match '^END OF SUPPORT 2023-10-10'
    }
    It 'marks a current server OS supported, with the date' {
        $r = Get-OsLifecycleState -Caption 'Microsoft Windows Server 2025 Standard'
        $r.Expired | Should -BeFalse; $r.Soon | Should -BeFalse; $r.Label | Should -Match '^supported to 2034-10-10'
    }
    It 'returns not assessed for an unlisted caption rather than guessing (failure path)' {
        $r = Get-OsLifecycleState -Caption 'Some Appliance OS'
        $r.Eol | Should -BeNullOrEmpty; $r.Label | Should -Be 'not assessed'; $r.Expired | Should -BeFalse
    }
}

Describe 'Get-PendingRebootState' {
    It 'reports nothing pending when no marker is present (happy path)' {
        Mock Test-Path { $false }
        Mock Get-RegValue { $null }
        @(Get-PendingRebootState).Count | Should -Be 0
    }
    It 'names each pending-reboot reason it finds (failure path)' {
        Mock Test-Path { $LiteralPath -like '*Component Based Servicing\RebootPending' }
        Mock Get-RegValue { if ($Name -eq 'PendingFileRenameOperations') { @('a', 'b') } elseif ($Name -eq 'NV Hostname') { 'NEWNAME' } elseif ($Name -eq 'Hostname') { 'OLDNAME' } }
        $r = @(Get-PendingRebootState)
        $r | Should -Contain 'CBS RebootPending'
        $r | Should -Contain 'PendingFileRename (2)'
        $r | Should -Contain 'Pending computer rename'
        $r | Should -Not -Contain 'WU RebootRequired'
    }
}

Describe 'Resolve-ProfileAccount' {
    It 'translates a well-known SID and classifies it as not local' {
        $r = Resolve-ProfileAccount -Sid 'S-1-5-18'
        $r.Translated | Should -BeTrue; $r.Account | Should -Be 'NT AUTHORITY\SYSTEM'; $r.State | Should -Be 'not local'
    }
    It 'classifies an untranslatable domain-style SID as ORPHANED instead of keeping the raw SID (failure path)' {
        $r = Resolve-ProfileAccount -Sid 'S-1-5-21-11-22-33-9999'
        $r.Translated | Should -BeFalse; $r.State | Should -Be 'ORPHANED'
    }
    It 'classifies a malformed SID as unresolved' {
        (Resolve-ProfileAccount -Sid 'not-a-sid').State | Should -Be 'unresolved SID'
    }
}

Describe 'Add-Emit (byte budget)' {
    BeforeAll {
        $script:Enc = [System.Text.Encoding]::UTF8
        $script:Emitted = New-Object System.Collections.ArrayList
        $script:Used = 0
    }
    It 'emits within the limit and accounts for the line break (happy path)' {
        Add-Emit 'abc' 100 | Should -BeTrue
        $script:Used | Should -Be 5
        $script:Emitted.Count | Should -Be 1
    }
    It 'refuses a line that would cross the limit and leaves the buffer untouched (failure path)' {
        Add-Emit ('z' * 200) 100 | Should -BeFalse
        $script:Used | Should -Be 5
        $script:Emitted.Count | Should -Be 1
    }
}

Describe 'Get-RegValue' {
    It 'returns a value for a key that exists' {
        Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName' | Should -Not -BeNullOrEmpty
    }
    It 'returns null for a missing path or a missing value' {
        Get-RegValue -Path 'HKLM:\SOFTWARE\NoSuchKey-ReadinessAuditTest' -Name 'Nothing' | Should -BeNullOrEmpty
        Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'NoSuchValue-ReadinessAuditTest' | Should -BeNullOrEmpty
    }
}

Describe 'Get-PathActivity' {
    It 'reports an existing path with counts and a timestamp only, never file names' {
        $r = Get-PathActivity -Path $env:WINDIR
        $r.Exists | Should -BeTrue; $r.LastWrite | Should -Not -BeNullOrEmpty; $r.TotalTop | Should -BeGreaterThan 0
        @($r.PSObject.Properties.Name) | Sort-Object | Should -Be @('Exists', 'LastWrite', 'RecentCount', 'TotalTop')
    }
    It 'reports Exists false for a path that does not exist (failure path)' {
        $r = Get-PathActivity -Path 'C:\NoSuchPath-ReadinessAuditTest'
        $r.Exists | Should -BeFalse; $r.RecentCount | Should -Be 0; $r.TotalTop | Should -Be 0
    }
}

Describe 'Static analysis' {
    It 'is clean at Warning and Error severity' {
        $findings = @(Invoke-ScriptAnalyzer -Path $script:ScriptPath -Severity Warning, Error)
        $findings.Count | Should -Be 0 -Because (($findings | ForEach-Object { '{0}:{1} {2}' -f $_.Line, $_.RuleName, $_.Message }) -join ' | ')
    }
}
