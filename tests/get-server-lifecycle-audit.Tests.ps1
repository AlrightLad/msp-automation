#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests for oem-dell/get-server-lifecycle-audit.ps1

    The script guards its main block behind $MyInvocation.InvocationName, so it
    can be dot-sourced to load Get-ServerLifecycleAudit without running the
    audit, writing a transcript or taking the mutex. The collector is then run
    against a mocked CIM layer for a happy path and a failure path, and the
    RMM-safety contract is asserted structurally. Pester 5.x and 6.x.
#>

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\oem-dell\get-server-lifecycle-audit.ps1')).Path
    $script:Content    = Get-Content -LiteralPath $script:ScriptPath -Raw
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors)
    $script:ParseErrors = @($errors)

    . $script:ScriptPath
    # Dot-sourcing adopts the script's $ErrorActionPreference = 'Stop'; keep it,
    # the collector's own try/catch structure assumes it.
}

Describe 'RMM-safety contract' {
    It 'parses without syntax errors' {
        $script:ParseErrors.Count | Should -Be 0 -Because (($script:ParseErrors | ForEach-Object { $_.Message }) -join '; ')
    }
    It 'has comment-based help with a synopsis, description and notes' {
        $help = $script:Ast.GetHelpContent()
        $help             | Should -Not -BeNullOrEmpty
        $help.Synopsis    | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
        $help.Notes       | Should -Match 'Exit codes'
    }
    It 'declares its real minimum version and says why it is below 5.1' {
        $script:Content | Should -Match '#Requires\s+-Version\s+3\.0'
        $script:Ast.GetHelpContent().Notes | Should -Match 'declares 3\.0'
    }
    It 'uses no PowerShell 5.0-only syntax' {
        $script:Content | Should -Not -Match '::new\('
        $script:Content | Should -Not -Match '\bWrite-Information\b'
        $script:Content | Should -Not -Match '\bclass\s+\w+\s*\{'
    }
    It 'contains no Read-Host and no switch parameters' {
        $script:Content | Should -Not -Match '\bRead-Host\b'
        @($script:Ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.ParameterAst] -and $n.StaticType.Name -eq 'SwitchParameter'
                }, $true)).Count | Should -Be 0
    }
    It 'declares no mandatory parameters (would hang an unattended RMM run)' {
        $script:Content | Should -Not -Match '\[Parameter\([^)]*Mandatory'
    }
    It 'takes a single-instance mutex and survives an abandoned one' {
        $script:Content | Should -Match 'System\.Threading\.Mutex'
        $script:Content | Should -Match 'AbandonedMutexException'
        $script:Content | Should -Match 'ReleaseMutex'
    }
    It 'writes a transcript and rotates by retention count' {
        $script:Content | Should -Match '\bStart-Transcript\b'
        $script:Content | Should -Match 'Select-Object -Skip \$logRetention'
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
    It 'guards the main block so dot-sourcing for tests does not execute it' {
        $script:Content | Should -Match "MyInvocation\.InvocationName -ne '\.'"
        Get-Command Get-ServerLifecycleAudit -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'carries no organisation, client, ticket or knowledge-base identifiers' {
        $script:Content | Should -Not -Match 'DTC|\bKB ?\d|SFT-\d|\d{7}'
    }
}

Describe 'Get-ServerLifecycleAudit' {
    Context 'against a mocked PowerEdge T340 (happy path)' {
        BeforeAll {
            Mock Get-CimInstance {
                switch ($ClassName) {
                    'Win32_ComputerSystem'      { [pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'PowerEdge T340'; DomainRole = 3 } }
                    'Win32_BIOS'                { [pscustomobject]@{ SerialNumber = 'TESTTAG1'; SMBIOSBIOSVersion = '2.0.0' } }
                    'Win32_Processor'           { [pscustomobject]@{ Name = 'Intel Xeon E-2234 '; NumberOfCores = 4; NumberOfLogicalProcessors = 8 } }
                    'Win32_PhysicalMemory'      { [pscustomobject]@{ Capacity = 16GB }; [pscustomobject]@{ Capacity = 16GB } }
                    'Win32_PhysicalMemoryArray' { [pscustomobject]@{ MaxCapacityEx = 64MB; MaxCapacity = $null; MemoryDevices = 4 } }
                    'Win32_NetworkAdapter'      { @() }
                    'Win32_OperatingSystem'     { [pscustomobject]@{ Caption = 'Microsoft Windows Server 2019 Standard'; Version = '10.0.17763'; OSArchitecture = '64-bit'; InstallDate = (Get-Date '2020-01-01') } }
                    'Win32_LogicalDisk'         { [pscustomobject]@{ DeviceID = 'C:'; FreeSpace = 50GB; Size = 200GB } }
                    'Win32_Tpm'                 { [pscustomobject]@{ SpecVersion = '2.0, 0, 1.59' } }
                    default                     { $null }
                }
            }
            $script:Report = Get-ServerLifecycleAudit -ClientName 'UnitTestClient'
            $script:Lines  = $script:Report -split "`r`n"
        }
        It 'returns a single text report' {
            $script:Report | Should -BeOfType [string]
            $script:Lines.Count | Should -BeGreaterThan 30
        }
        It 'puts the client and host in the header' {
            $script:Report | Should -Match ' SERVER LIFECYCLE AUDIT  \(read-only\)'
            $script:Report | Should -Match ' Client : UnitTestClient'
            $script:Report | Should -Match (' Host   : ' + [regex]::Escape($env:COMPUTERNAME))
        }
        It 'reports the mocked identity and sizing' {
            $script:Report | Should -Match 'Model           : PowerEdge T340'
            $script:Report | Should -Match 'Service Tag     : TESTTAG1'
            $script:Report | Should -Match 'Sockets/Cores   : 1 socket\(s\), 4 physical, 8 logical'
            $script:Report | Should -Match 'RAM installed   : 32 GB   \(slots used 2 of 4\)'
            $script:Report | Should -Match 'RAM max         : 64 GB'
        }
        It 'infers generation and iDRAC family from the model number' {
            $script:Report | Should -Match 'Generation      : 14G \(inferred from model\)'
            $script:Report | Should -Match 'iDRAC gen       : iDRAC9 \(inferred from model\)'
        }
        It 'treats a member server as not a domain controller' {
            $script:Report | Should -Match 'Domain role     : 3 \(member/standalone\)'
            $script:Report | Should -Match 'Not a DC - pull enabled user \+ workstation counts'
        }
        It 'emits every section and the decision summary' {
            foreach ($s in '== IDENTITY / HARDWARE ==', '== OPERATING SYSTEM ==', '== DISK / STORAGE ==', '== SERVER ROLES ==', '== CAL SIZING INPUTS', 'Gate 1 OS ceiling', 'Upgrade gate \(2022\)') {
                $script:Report | Should -Match $s
            }
        }
        It 'contains no placeholder-less internal identifiers' {
            $script:Report | Should -Not -Match 'DTC|KB \d|SFT-'
        }
    }

    Context 'when the CIM layer is unavailable (failure path)' {
        BeforeAll { Mock Get-CimInstance { throw 'WMI repository unavailable' } }
        It 'throws rather than returning a partial report' {
            { Get-ServerLifecycleAudit -ClientName 'x' } | Should -Throw '*WMI repository unavailable*'
        }
    }

    Context 'inference edge cases' {
        BeforeAll {
            Mock Get-CimInstance {
                switch ($ClassName) {
                    'Win32_ComputerSystem'      { [pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'PowerEdge T330'; DomainRole = 2 } }
                    'Win32_BIOS'                { [pscustomobject]@{ SerialNumber = 'TAG330'; SMBIOSBIOSVersion = '1.0' } }
                    'Win32_Processor'           { [pscustomobject]@{ Name = 'CPU'; NumberOfCores = 2; NumberOfLogicalProcessors = 4 } }
                    'Win32_PhysicalMemory'      { [pscustomobject]@{ Capacity = 8GB } }
                    'Win32_PhysicalMemoryArray' { [pscustomobject]@{ MaxCapacityEx = $null; MaxCapacity = 32MB; MemoryDevices = 4 } }
                    'Win32_OperatingSystem'     { [pscustomobject]@{ Caption = 'Microsoft Windows Server 2012 R2 Standard'; Version = '6.3.9600'; OSArchitecture = '64-bit'; InstallDate = (Get-Date '2016-01-01') } }
                    'Win32_LogicalDisk'         { @() }
                    default                     { $null }
                }
            }
        }
        It 'maps a 13th-generation model to iDRAC8 and falls back to MaxCapacity' {
            $r = Get-ServerLifecycleAudit -ClientName 'edge'
            $r | Should -Match 'Generation      : 13G'
            $r | Should -Match 'iDRAC gen       : iDRAC8'
            $r | Should -Match 'RAM max         : 32 GB'
        }
    }
}
