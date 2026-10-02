#Requires -Version 5.1
<#
    Pester tests for backup-veeam/Set-VeeamScheduleWindow.ps1

    The script is never executed: its body talks to a live Veeam server. The
    pure helpers (hour-set and scheduler-XML builders, RMM input parsing) are
    lifted out of the AST and tested in isolation, and the RMM-safety contract
    is asserted structurally. Pester 5.x and 6.x.
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\backup-veeam\Set-VeeamScheduleWindow.ps1')).Path
    $script:Content    = Get-Content -LiteralPath $script:ScriptPath -Raw
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors)
    $script:ParseErrors = @($errors)

    foreach ($fn in 'Get-IntVar', 'Get-DayIdx', 'Get-PermittedHourSet', 'New-SchedulerXml') {
        $node = $script:Ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn
            }, $true) | Select-Object -First 1
        if (-not $node) { throw "$fn not found in script" }
        . ([scriptblock]::Create($node.Extent.Text))
    }
    # The helpers read this script-scope constant exactly as the script defines it.
    $script:DayNames = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
}

Describe 'RMM-safety contract' {
    It 'parses without syntax errors' {
        $script:ParseErrors.Count | Should -Be 0 -Because (($script:ParseErrors | ForEach-Object { $_.Message }) -join '; ')
    }
    It 'has comment-based help with a synopsis and notes' {
        $help = $script:Ast.GetHelpContent()
        $help          | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -BeNullOrEmpty
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
        $script:Content | Should -Match 'Select-Object -Skip \$LogRetention'
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
    It 'carries no organisation, host or ticket identifiers' {
        $script:Content | Should -Not -Match 'DTC|HALO|\d{7}'
    }
}

Describe 'Get-PermittedHourSet' {
    It 'returns the half-open range for a same-day window' {
        $h = Get-PermittedHourSet -Start 6 -End 21
        $h.Count | Should -Be 15
        $h[0]    | Should -Be 6
        $h[-1]   | Should -Be 20
    }
    It 'wraps past midnight when Start is after End' {
        $h = Get-PermittedHourSet -Start 22 -End 5
        $h.Count | Should -Be 7
        $h | Should -Contain 23
        $h | Should -Contain 0
        $h | Should -Contain 4
        $h | Should -Not -Contain 5
    }
    It 'permits no hour at all for a zero-width window (failure path)' {
        # The function returns its array through a unary comma, so the empty
        # case is an empty inner array; assert on membership, not Count.
        $h = Get-PermittedHourSet -Start 8 -End 8
        @($h | Where-Object { $_ -is [int] }).Count | Should -Be 0
        $h -contains 8 | Should -BeFalse
    }
}

Describe 'New-SchedulerXml' {
    BeforeAll {
        $script:Xml = New-SchedulerXml -PermittedHours (Get-PermittedHourSet -Start 6 -End 21) -PermittedDays @(1, 2, 3, 4, 5)
        $script:Doc = [xml]$script:Xml
    }
    It 'emits seven day elements with 24 values each' {
        $script:Doc.scheduler.ChildNodes.Count | Should -Be 7
        foreach ($day in $script:Doc.scheduler.ChildNodes) {
            ($day.InnerText -split ',').Count | Should -Be 24 -Because $day.Name
        }
    }
    It 'uses inverted polarity: 0 permitted, 1 denied' {
        $monday = ($script:Doc.scheduler.Monday -split ',')
        $monday[6]  | Should -Be '0'
        $monday[20] | Should -Be '0'
        $monday[5]  | Should -Be '1'
        $monday[21] | Should -Be '1'
    }
    It 'denies every hour of a day that is not permitted' {
        ($script:Doc.scheduler.Sunday -split ',') | Should -Not -Contain '0'
        ($script:Doc.scheduler.Saturday -split ',') | Should -Not -Contain '0'
    }
    It 'opens a FullDays day for all 24 hours regardless of the hour set' {
        $copy = [xml](New-SchedulerXml -PermittedHours (Get-PermittedHourSet -Start 22 -End 5) -PermittedDays @(1, 2, 3, 4, 5, 6) -FullDays @(0))
        ($copy.scheduler.Sunday -split ',') | Should -Not -Contain '1'
        ($copy.scheduler.Monday -split ',')[12] | Should -Be '1'
        ($copy.scheduler.Monday -split ',')[23] | Should -Be '0'
    }
}

Describe 'RMM input parsing' {
    AfterAll { Remove-Item Env:\PesterSetVeeamIntVar -ErrorAction SilentlyContinue }

    It 'Get-DayIdx maps abbreviated day names to indexes' {
        Get-DayIdx -Raw 'Mon,Tue,Wed,Thu,Fri' -Default @(0) | Should -Be @(1, 2, 3, 4, 5)
        Get-DayIdx -Raw 'Sat, Sun' -Default @(0)           | Should -Be @(0, 6)
    }
    It 'Get-DayIdx falls back to the default on unparseable input (failure path)' {
        Get-DayIdx -Raw 'Xyz,Qqq' -Default @(1, 2, 3, 4, 5) | Should -Be @(1, 2, 3, 4, 5)
        Get-DayIdx -Raw ''        -Default @(1, 2, 3, 4, 5) | Should -Be @(1, 2, 3, 4, 5)
    }
    It 'Get-IntVar reads an integer from the environment' {
        $env:PesterSetVeeamIntVar = '42'
        Get-IntVar -Name 'PesterSetVeeamIntVar' -Default 7 | Should -Be 42
    }
    It 'Get-IntVar falls back to the default for a non-numeric or missing value (failure path)' {
        $env:PesterSetVeeamIntVar = 'abc'
        Get-IntVar -Name 'PesterSetVeeamIntVar' -Default 7 | Should -Be 7
        Remove-Item Env:\PesterSetVeeamIntVar -ErrorAction SilentlyContinue
        Get-IntVar -Name 'PesterSetVeeamIntVar' -Default 7 | Should -Be 7
    }
}
