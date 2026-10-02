#Requires -Version 5.1
<#
    Pester tests for backup-veeam/Invoke-VeeamV13Upgrade.ps1

    The script is never executed: it stops services, installs software and
    reboots. The decision helpers that take plain data (copy-job status
    classification, setup-report parsing, ISO hash verification, installer
    event-id harvesting, the reboot-once marker) are lifted out of the AST
    and tested in isolation; the RMM-safety contract is asserted
    structurally. Pester 5.x and 6.x.
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\backup-veeam\Invoke-VeeamV13Upgrade.ps1')).Path
    $script:Content    = Get-Content -LiteralPath $script:ScriptPath -Raw
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors)
    $script:ParseErrors = @($errors)

    # The helpers under test log through Write-Log on their error paths; a
    # recording stub stands in for the script's host-stream logger.
    $script:LogLines = New-Object System.Collections.Generic.List[string]
    function Write-Log {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
            Justification = 'Test double for the script''s own Write-Log shim; the helpers under test call it by this name.')]
        param([string]$Message, [string]$Level = 'INFO')
        $script:LogLines.Add("[$Level] $Message")
    }

    foreach ($fn in 'Get-PostUpgradeCopyStatus', 'Get-SetupReportAgentBlockers', 'Test-IsoHash',
                    'Get-InstallerEventIds', 'Get-RebootMarker', 'Set-RebootMarker', 'Clear-RebootMarker') {
        $node = $script:Ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn
            }, $true) | Select-Object -First 1
        if (-not $node) { throw "$fn not found in script" }
        . ([scriptblock]::Create($node.Extent.Text))
    }
    $script:TempDir = Join-Path ([IO.Path]::GetTempPath()) ("pester-veeam-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
    # The helpers read these script-scope folders the way the script defines them.
    $script:LogFolder       = Join-Path $script:TempDir 'logs'
    $script:SetupTempFolder = Join-Path $script:TempDir 'setup'
    New-Item -ItemType Directory -Path $script:LogFolder, $script:SetupTempFolder -Force | Out-Null
}

AfterAll {
    if ($script:TempDir -and (Test-Path -LiteralPath $script:TempDir)) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'RMM-safety contract' {
    It 'parses without syntax errors' {
        $script:ParseErrors.Count | Should -Be 0 -Because (($script:ParseErrors | ForEach-Object { $_.Message }) -join '; ')
    }
    It 'has comment-based help that documents every RMM input' {
        $help = $script:Ast.GetHelpContent()
        $help          | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -BeNullOrEmpty
        foreach ($v in 'downloadUrlV13', 'preflightOnly', 'orgName', 'installAdminUser', 'lapsFieldName', 'enablePatch', 'stopServicesForPatch', 'holdForCopyWatch') {
            $help.Notes | Should -Match $v -Because "RMM variable $v must be documented"
        }
    }
    It 'declares PowerShell 5.1 as the minimum' {
        $script:Content | Should -Match '#Requires\s+-Version\s+5\.1'
    }
    It 'contains no Read-Host and no switch parameters' {
        $script:Content | Should -Not -Match '\bRead-Host\b'
        @($script:Ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.StaticType.Name -eq 'SwitchParameter'
                }, $true)).Count | Should -Be 0 -Because 'switch parameters do not bind from RMM preset variables'
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
    It 'relaunches 64-bit from a 32-bit host before the transcript starts' {
        $script:Content.IndexOf('PROCESSOR_ARCHITEW6432') | Should -BeLessThan $script:Content.IndexOf('Start-Transcript')
    }
    It 'uses only exit codes 0, 1 and 2' {
        $exits = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))
        $exits.Count | Should -BeGreaterThan 5
        foreach ($e in $exits) {
            $expr = $e.Pipeline.Extent.Text.Trim()
            if ($expr -match '^\d+$') { [int]$expr | Should -BeIn @(0, 1, 2) -Because "exit $expr at line $($e.Extent.StartLineNumber)" }
        }
    }
    It 'restores paused jobs and the management agent in finally on every path' {
        $finallyIdx = $script:Content.LastIndexOf('finally {')
        $script:Content.Substring($finallyIdx) | Should -Match 'Restore-PausedJobsFromMemory'
        $script:Content.Substring($finallyIdx) | Should -Match 'Restore-VeeamJobs'
        $script:Content.Substring($finallyIdx) | Should -Match 'Restore-SpcManagementAgent'
    }
    It 'never writes the install credential to the log' {
        $script:Content | Should -Not -Match 'Write-Log[^\r\n]*\$AdminPassword'
        $script:Content | Should -Not -Match 'Write-Log[^\r\n]*\$PlainPassword'
    }
    It 'carries no organisation, host, account or ticket identifiers' {
        $script:Content | Should -Not -Match 'DTC|HALO|\d{7}|dtcadmin'
    }
}

Describe 'Get-PostUpgradeCopyStatus' {
    BeforeAll {
        $script:Since = [datetime]::Parse('2026-09-01T00:00:00Z').ToUniversalTime()
        $script:Baseline = @(
            [pscustomobject]@{ name = 'Copy-A'; enabled = $true;  lastResult = 'Success' }   # healthy, ran after upgrade
            [pscustomobject]@{ name = 'Copy-B'; enabled = $true;  lastResult = 'Success' }   # healthy, not yet run
            [pscustomobject]@{ name = 'Copy-C'; enabled = $true;  lastResult = 'Failed'  }   # already broken at baseline
            [pscustomobject]@{ name = 'Copy-D'; enabled = $false; lastResult = 'Success' }   # disabled: ignored
            [pscustomobject]@{ name = 'Copy-E'; enabled = $true;  lastResult = 'Warning' }   # healthy, failed after upgrade
        )
        $script:Sessions = @(
            [pscustomobject]@{ jobName = 'Copy-A'; result = 'Success'; createdUtc = '2026-09-02T01:00:00Z' }
            [pscustomobject]@{ jobName = 'Copy-A'; result = 'Failed';  createdUtc = '2026-08-30T01:00:00Z' }   # before upgrade: ignored
            [pscustomobject]@{ jobName = 'Copy-E'; result = 'Failed';  createdUtc = '2026-09-02T02:00:00Z' }
        )
        $script:Result = Get-PostUpgradeCopyStatus -BaselineCopyJobs $script:Baseline -LiveSessions $script:Sessions -SinceUtc $script:Since
    }
    It 'reports a healthy job with a post-upgrade success as Succeeded (happy path)' {
        $script:Result.Succeeded | Should -Contain 'Copy-A'
    }
    It 'reports a healthy job with no post-upgrade session as NotYet' {
        $script:Result.NotYet | Should -Contain 'Copy-B'
    }
    It 'reports a job that was already failing at baseline as PreBroken, not Failed' {
        $script:Result.PreBroken | Should -Contain 'Copy-C'
        ($script:Result.Failed -join ' ') | Should -Not -Match 'Copy-C'
    }
    It 'ignores disabled jobs' {
        ($script:Result.Succeeded + $script:Result.NotYet + $script:Result.Failed + $script:Result.PreBroken) | Should -Not -Contain 'Copy-D'
    }
    It 'reports a healthy job that failed after the upgrade as Failed (failure path)' {
        $script:Result.Failed.Count | Should -Be 1
        $script:Result.Failed[0]    | Should -Match '^Copy-E '
    }
    It 'does not count a pre-upgrade failure against a job' {
        ($script:Result.Failed -join ' ') | Should -Not -Match 'Copy-A'
    }
}

Describe 'Get-SetupReportAgentBlockers' {
    It 'extracts agent names from error-severity agent issues (happy path)' {
        $xmlPath = Join-Path $script:TempDir 'report.xml'
        @'
<?xml version="1.0" encoding="utf-8"?>
<report>
  <issue severity="error" title="Outdated Veeam Agents detected">
    <object name="WS-ONE (agent 6.0.0.960)" />
    <object name="WS-TWO" />
  </issue>
  <issue severity="warning" title="Something minor" />
  <issue severity="error" title="Configuration database is in an unsupported state" />
</report>
'@ | Set-Content -LiteralPath $xmlPath -Encoding UTF8
        $r = Get-SetupReportAgentBlockers -ReportPath $xmlPath
        $r.Names       | Should -Be @('WS-ONE', 'WS-TWO')
        $r.Titles      | Should -Contain 'Outdated Veeam Agents detected'
        $r.OtherErrors | Should -Be @('Configuration database is in an unsupported state')
    }
    It 'returns empty collections when the report does not exist (failure path)' {
        $r = Get-SetupReportAgentBlockers -ReportPath (Join-Path $script:TempDir 'missing.xml')
        @($r.Names).Count       | Should -Be 0
        @($r.Titles).Count      | Should -Be 0
        @($r.OtherErrors).Count | Should -Be 0
    }
    It 'logs and returns empty collections on a malformed report (failure path)' {
        $bad = Join-Path $script:TempDir 'bad.xml'
        'not xml at all <<<' | Set-Content -LiteralPath $bad -Encoding UTF8
        $script:LogLines.Clear()
        $r = Get-SetupReportAgentBlockers -ReportPath $bad
        @($r.Names).Count | Should -Be 0
        ($script:LogLines -join "`n") | Should -Match 'Could not parse setup report'
    }
}

Describe 'Test-IsoHash' {
    BeforeAll {
        $script:IsoStub = Join-Path $script:TempDir 'stub.iso'
        [IO.File]::WriteAllBytes($script:IsoStub, [byte[]](1..64))
        $script:GoodHash = (Get-FileHash -LiteralPath $script:IsoStub -Algorithm SHA256).Hash
    }
    It 'accepts the correct SHA256 regardless of case or surrounding whitespace (happy path)' {
        Test-IsoHash -Path $script:IsoStub -Expected ("  " + $script:GoodHash.ToLower() + " ") | Should -BeTrue
    }
    It 'rejects a wrong SHA256 (failure path)' {
        Test-IsoHash -Path $script:IsoStub -Expected ('0' * 64) | Should -BeFalse
    }
    It 'records the computed hash in the log so a mismatch is diagnosable' {
        $script:LogLines.Clear()
        $null = Test-IsoHash -Path $script:IsoStub -Expected $script:GoodHash
        ($script:LogLines -join "`n") | Should -Match ([regex]::Escape($script:GoodHash))
    }
}

Describe 'Get-InstallerEventIds' {
    BeforeAll {
        # UTF-8 installer stderr with two event ids, one repeated; a UTF-16 result document
        # (how setup writes it) carrying one of them again.
        'event id="102" "Invalid answer file provided."' + "`r`n" + 'event id="1603" fatal' + "`r`n" + 'event id="102" again' |
            Set-Content -LiteralPath (Join-Path $script:LogFolder 'installer-stderr.txt') -Encoding UTF8
        [IO.File]::WriteAllText((Join-Path $script:SetupTempFolder 'UnattendedInstallationResult_1.xml'),
            '<result><event id="102" /></result>', [Text.Encoding]::Unicode)
    }
    It 'harvests unique event ids across UTF-8 and UTF-16 sources (happy path)' {
        $r = Get-InstallerEventIds -SinceUtc ([datetime]::UtcNow.AddHours(-1))
        $r | Should -Not -BeNullOrEmpty
        @($r.Ids) | Should -Be @('102', '1603')
    }
    It 'returns an object with an empty Ids list, never $null, when every source predates the attempt (failure path)' {
        $r = Get-InstallerEventIds -SinceUtc ([datetime]::UtcNow.AddHours(1))
        $r | Should -Not -BeNullOrEmpty
        @($r.Ids).Count | Should -Be 0
    }
}

Describe 'Reboot-once marker' {
    BeforeAll {
        $script:BootAt = [datetime]::UtcNow.AddHours(-2)
        Mock Get-CimInstance { [pscustomobject]@{ LastBootUpTime = $script:BootAt } }
    }
    It 'reads nothing when no marker exists' {
        Get-RebootMarker -Name 'none' | Should -BeNullOrEmpty
    }
    It 'records a reboot and reports that the box has not booted since (happy path)' {
        Set-RebootMarker -Name 'wedge'
        $m = Get-RebootMarker -Name 'wedge'
        $m | Should -Not -BeNullOrEmpty
        $m.rebootedSince | Should -BeFalse
        [datetime]::Parse($m.rebootedUtc).ToUniversalTime() | Should -BeGreaterThan $script:BootAt
    }
    It 'reports a reboot that has happened since the marker was written' {
        $script:BootAt = [datetime]::UtcNow.AddHours(1)
        (Get-RebootMarker -Name 'wedge').rebootedSince | Should -BeTrue
    }
    It 'treats a malformed marker as absent rather than throwing (failure path)' {
        'not json' | Set-Content -LiteralPath (Join-Path $script:LogFolder 'reboot-bad.json') -Encoding UTF8
        Get-RebootMarker -Name 'bad' | Should -BeNullOrEmpty
    }
    It 'clears a marker so the next run can reboot once again' {
        Clear-RebootMarker -Name 'wedge'
        Get-RebootMarker -Name 'wedge' | Should -BeNullOrEmpty
    }
}
