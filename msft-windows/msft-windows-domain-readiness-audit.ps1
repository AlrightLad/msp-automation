<#
.SYNOPSIS
    Read-only workgroup-to-domain readiness audit. Built for NinjaOne delivery.

.DESCRIPTION
    Answers four questions for a domain conversion:

      1. WHICH PROFILES MOVE - named, with per-profile and total size
      2. WHICH VENDORS TO CALL - practice platforms and database engines mapped
         to the vendor whose domain-join support statement you need
      3. HOW MUCH DATA - accurate sizes from a reparse-safe walk
      4. EVERY LINE OF THE READINESS CHECKLIST - answered with data, marked N/A
         with a reason, or listed under MANUAL CAPTURE REQUIRED with the source
         to get it from. No ID is ever silently absent.

    Makes NO changes. No registry writes, no service control, no permission
    changes. Does not enumerate file names inside practice-management or imaging
    data directories - counts and timestamps only.

    OUTPUT IS BYTE-BUDGETED. NinjaOne truncates script output at exactly 10,003
    bytes, mid-line, no marker. Measured across 288 activity records: 148
    truncated, all exactly 10,003 bytes, zero spread, line counts varying 79-158.
    Conclusively a byte cap, undocumented in the API spec.

.NOTES
    Author  : Z. Boogher
    Version : 2.6.1

    NinjaOne preset variables (all optional):
      AUDIT_Client           Client / site label. Default UNSPECIFIED.
      AUDIT_Ticket           Ticket reference. Default UNSPECIFIED.
      AUDIT_SkipProfileSize  '1' to skip sizing. Default OFF - sizing runs.
      AUDIT_ProfileDays      Activity window in days. Default 90.
      AUDIT_CaptureDir       Directory for pre-join state exports. Default off.
      AUDIT_OutputBudget     Byte budget. Default 9600, hard-capped at 9900.
      AUDIT_LogPath          Transcript directory. Default %ProgramData%\<ORG>\Logs.
      AUDIT_OrgName          Organisation folder under %ProgramData% for the default log path. Default ORG.
      AUDIT_LogRetention     Transcripts retained. Default 10.
      AUDIT_MaxListItems     Cap per enumerated list. Default 60.

    Byte-budget floors are CODE CONSTANTS, not variables - no operator input.

    ---- 2.6.1 CHANGES ----

    1. SCOPE FLOOR. 2.6.0 left the scope section 900 bytes after reserving the
       later floors. On a 19-profile application server the packed name list
       consumed it and the VENDORS TO CONTACT block never emitted at all -
       a stated deliverable missing from the highest-value section. Floors
       rebalanced to 2000/700/4200, giving scope 2100.

    2. VENDOR ORDER. Vendors now emit BEFORE the profile name list. The vendor
       list is short and bounded; the name list is neither. The bounded thing
       goes first so the unbounded thing absorbs any pressure.

    3. SERVICE ACCOUNT PROFILES. SQLTELEMETRY$<instance>, MSSQLFDLauncher$
       <instance> and similar resolve to NT SERVICE principals, so the local-
       account lookup returned 'not local' and activity fell through to
       LastUseTime - the unreliable signal. Three such entries appeared on a
       move list as if they were people. Now identified and excluded, counted
       separately.

    4. MANUAL CAPTURE. OPEN checklist rows are grouped by the source that
       answers them - network controller, backup console, RMM, AM, dispatch,
       engineering, on-site - so the report doubles as a per-owner to-do list
       rather than a set of IDs to look up.

    5. ADMIN PROFILE REVIEW. Profiles on the move list whose account name looks
       administrative or service-related are flagged for review. Field case: a
       prior IT provider's 11 GB profile was correctly active by LastLogon and
       correctly on the move list, but should not be transferred into the new
       domain. The script cannot know that; it can surface it.

    Known-defect fixes carried forward:
      - Exit code (2.6.0): 2.5.x returned exit 2 whenever any flag was raised,
        which is the normal case. NinjaOne treats non-zero as FAILURE, so all
        153 devices reported failed. Exit is 0 on success; 1 for a real error.
      - Template completeness (2.6.0): every checklist ID registered up front, so
        a site without a session host shows N/A rather than the ID being absent
        and indistinguishable from "not audited".
      - Virtualisation (2.5.1): the vmicheartbeat fallback tested service
        EXISTENCE. Integration Services ship in-box since 8.1 / 2012 R2, so the
        service exists stopped on physical machines and the test always passed.
        Field result: 13 of 13 devices at one site, including a physical
        PowerEdge T360 Hyper-V HOST, classified as guests with real Dell service
        tags labelled hypervisor GUIDs. Replaced with the guest-side integration
        registry key, plus a conflict flag against physical OEMs.
      - Profile size (2.2.0): Get-ChildItem -Recurse follows the legacy profile
        junctions and re-counts until MAX_PATH. Field result: 350+ GB profiles
        on 118 GB volumes. Replaced with a reparse-safe manual walk.
      - Profile activity (2.2.0): Win32_UserProfile.LastUse moves on
        non-interactive enumeration. Confirmed: account '<USER1>' showed LastUse
        2026-08-24 while DISABLED with a last real logon of 2024-11-19.
      - Orphaned profiles (2.5.0): a failed SID translation left a raw SID that
        never matched the local-account prefix test, so deleted-account profiles
        could be counted active and land on the move list.
      - Referenced hosts (2.2.0): SQL Anywhere CommLinks values (TCPIP, SHMEM)
        are protocol keywords, not hostnames.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'The share-permission section sets $needs on every finding so the loop body reads as a checklist; the flags it raises are the output. Preserved as shipped.')]
param()

if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -and -not $env:AUDIT_RELAUNCHED) {
    $selfPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($selfPath)) { $selfPath = $MyInvocation.MyCommand.Definition }
    if (-not [string]::IsNullOrWhiteSpace($selfPath) -and (Test-Path -LiteralPath $selfPath)) {
        $env:AUDIT_RELAUNCHED = '1'
        $nativeShell = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $nativeShell) {
            & $nativeShell -NoProfile -ExecutionPolicy Bypass -File $selfPath
            exit $LASTEXITCODE
        }
    }
}

#Requires -Version 5.1

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------
$ClientLabel = $env:AUDIT_Client
if ([string]::IsNullOrWhiteSpace($ClientLabel)) { $ClientLabel = 'UNSPECIFIED' }

$TicketLabel = $env:AUDIT_Ticket
if ([string]::IsNullOrWhiteSpace($TicketLabel)) { $TicketLabel = 'UNSPECIFIED' }

$MeasureProfiles = ($env:AUDIT_SkipProfileSize -ne '1')

$ProfileDays = 90
if ($env:AUDIT_ProfileDays -match '^\d+$') { $ProfileDays = [int]$env:AUDIT_ProfileDays }

$CaptureDir = $env:AUDIT_CaptureDir
$DoCapture  = -not [string]::IsNullOrWhiteSpace($CaptureDir)

$OrgName = $env:AUDIT_OrgName
if ([string]::IsNullOrWhiteSpace($OrgName)) { $OrgName = 'ORG' }

$LogDir = $env:AUDIT_LogPath
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $env:ProgramData ($OrgName + '\Logs') }

$LogRetention = 10
if ($env:AUDIT_LogRetention -match '^\d+$') { $LogRetention = [int]$env:AUDIT_LogRetention }

$MaxListItems = 60
if ($env:AUDIT_MaxListItems -match '^\d+$') { $MaxListItems = [int]$env:AUDIT_MaxListItems }

$OutputBudget = 9600
if ($env:AUDIT_OutputBudget -match '^\d+$') { $OutputBudget = [int]$env:AUDIT_OutputBudget }
if ($OutputBudget -gt 9900) { $OutputBudget = 9900 }

# ---------------------------------------------------------------------------
# CODE CONSTANTS - no operator input
# ---------------------------------------------------------------------------
$ScriptTag     = 'DomainReadinessAudit'
$ScriptVersion = '2.6.1'
$CompleteToken = '##AUDIT-COMPLETE##'

# Guaranteed byte floors, rebalanced in 2.6.1. Sum is 6900 of a 9000 ceiling,
# leaving scope 2100. 2.6.0 used 2600/900/4600 which left scope only 900 and
# silently dropped the vendor list on a profile-heavy application server.
$FloorChecklist = 2000
$FloorWorklist  =  700
$FloorFlags     = 4200

$MaxChecklistValue = 165
$MaxFlagText       = 235
$MaxWorklistText   = 240

# Profiles belonging to services, not people. These resolve to NT SERVICE or
# machine principals, so the local-account lookup returns 'not local' and
# activity falls through to LastUseTime - the unreliable signal. Excluded from
# the move list entirely.
$ServiceProfilePattern = '^(NT SERVICE\\|.*\$$)|^(SQLTELEMETRY|MSSQL|MSSQLFDLauncher|SQLAgent|SQLSERVERAGENT|MSOLAP|ReportServer|MSDTC|IUSR|IWAM|ASPNET|DefaultAppPool|WDAGUtilityAccount|systemprofile|LocalService|NetworkService|defaultuser\d)'

# Move-list entries worth a human look before transferring into a new domain.
$AdminProfilePattern = '(?i)^(administrator|admin|.*adm$|.*admin\d*|.*backup.*|.*svc.*|.*service.*|.*_sa$|sa)$'

$PhysicalOem = 'Dell|Hewlett|HP |HPE|Compaq|Lenovo|IBM|Supermicro|ASUS|ASUSTeK|Acer|Gigabyte|Micro-Star|MSI|ASRock|Biostar|Intel Corp|Fujitsu|Toshiba|Panasonic|Samsung|LG Elec|Apple|System76|Shuttle|Zotac|Foxconn|Quanta|Wistron|Inventec|Pegatron|Elitegroup|ECS|Equus|Razer|Alienware|NEC|Sony|Clevo|Insyde'

$VendorMap = @{
    'SoftDent'     = @{ Pattern = 'Carestream.*SoftDent|SoftDent';  Vendor = 'Carestream Dental' }
    'CS Imaging'   = @{ Pattern = 'CS Imaging|CSIS|CS Adapt';       Vendor = 'Carestream Dental' }
    'WinOMS'       = @{ Pattern = 'WinOMS';                         Vendor = 'Carestream Dental' }
    'Eaglesoft'    = @{ Pattern = 'Eaglesoft|Patterson';            Vendor = 'Patterson Dental' }
    'Dentrix'      = @{ Pattern = 'Dentrix';                        Vendor = 'Henry Schein One' }
    'Open Dental'  = @{ Pattern = 'Open ?Dental';                   Vendor = 'Open Dental Software' }
    'Sidexis'      = @{ Pattern = 'Sidexis';                        Vendor = 'Dentsply Sirona' }
    'Schick'       = @{ Pattern = 'Schick|\bIOSS\b';                Vendor = 'Dentsply Sirona' }
    'DEXIS'        = @{ Pattern = 'DEXIS';                          Vendor = 'DEXIS (Envista)' }
    'DTX Studio'   = @{ Pattern = 'DTX ?Studio';                    Vendor = 'Envista / Nobel' }
    'VixWin'       = @{ Pattern = 'VixWin';                         Vendor = 'Gendex / KaVo' }
    'Romexis'      = @{ Pattern = 'Romexis';                        Vendor = 'Planmeca' }
    'Vatech'       = @{ Pattern = 'Vatech|EzDent|EzServer';         Vendor = 'Vatech America' }
    'TigerView'    = @{ Pattern = 'TigerView|Tiger ?View';          Vendor = 'TigerView' }
    'Apteryx'      = @{ Pattern = 'Apteryx|XrayVision|XVWeb';       Vendor = 'Apteryx Imaging' }
    'MiPACS'       = @{ Pattern = 'MiPACS';                         Vendor = 'Medicor Imaging' }
    'Dolphin'      = @{ Pattern = 'Dolphin ?Imaging|Dolphin ?Mgmt'; Vendor = 'Dolphin Imaging' }
    'TDO'          = @{ Pattern = '\bTDO\b';                        Vendor = 'TDO Software' }
    'iDentalSoft'  = @{ Pattern = 'iDentalSoft';                    Vendor = 'iDentalSoft' }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:Detail        = New-Object System.Collections.ArrayList
$script:Flags         = New-Object System.Collections.ArrayList
$script:Worklist      = New-Object System.Collections.ArrayList
$script:MoveProfiles  = New-Object System.Collections.ArrayList
$script:AdminProfiles = New-Object System.Collections.ArrayList
$script:Vendors       = New-Object System.Collections.ArrayList
$script:DbEngines     = New-Object System.Collections.ArrayList
$script:DbAuth        = New-Object System.Collections.ArrayList
$script:RefHosts      = New-Object System.Collections.ArrayList
$script:Checklist     = New-Object System.Collections.ArrayList
$script:AclDump       = New-Object System.Collections.ArrayList
$script:SectionIndex  = New-Object System.Collections.ArrayList
$script:Blockers      = New-Object System.Collections.ArrayList
$script:AllProfiles   = @()
$script:VolumeUsed    = @{}
$script:MoveBytes     = [long]0
$script:ProfileActive = 0
$script:ProfileTotal  = 0
$script:ServiceProfiles = 0
$script:ExitCode      = 0
$script:Mutex         = $null
$script:MutexHeld     = $false
$script:Transcribing  = $false
$script:HostProvides  = ''

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Limit-Text {
    [CmdletBinding()]
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.Length -le $Max) { return $Text }
    return ($Text.Substring(0, $Max - 12) + '...[tscript]')
}

function Add-Detail {
    [CmdletBinding()]
    param([string]$Text = '')
    [void]$script:Detail.Add($Text)
}

function Add-DetailSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Add-Detail ''
    Add-Detail ('== ' + $Name.ToUpper() + ' ==')
    [void]$script:SectionIndex.Add([PSCustomObject]@{ Name = $Name; Start = $script:Detail.Count })
}

function Add-DetailKv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, $Value)
    if ($null -eq $Value -or "$Value" -eq '') { $Value = '(not set)' }
    Add-Detail ('{0,-26}: {1}' -f $Key, $Value)
}

function Add-DetailList {
    [CmdletBinding()]
    param([string[]]$Items, [string]$Label = 'item')
    $total = @($Items).Count
    $shown = 0
    foreach ($line in $Items) {
        if ($shown -ge $MaxListItems) { break }
        Add-Detail $line
        $shown++
    }
    if ($total -gt $shown) { Add-Detail ('  ... +{0} more {1}(s) - see transcript' -f ($total - $shown), $Label) }
}

function Add-Worklist {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    [void]$script:Worklist.Add((Limit-Text -Text $Text -Max $MaxWorklistText))
}

function Add-Blocker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $t = Limit-Text -Text $Text -Max 180
    if ($script:Blockers -notcontains $t) { [void]$script:Blockers.Add($t) }
}

function Add-Flag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $t = Limit-Text -Text $Text -Max $MaxFlagText
    if ($script:Flags -notcontains $t) { [void]$script:Flags.Add($t) }
}

function Register-Checklist {
    <#
        A checklist entry is a STATUS REGISTER, not a data dump. Source names
        where an OPEN item is obtained, so the report doubles as a per-owner
        manual-capture list rather than a set of IDs to look up.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('CAPTURED', 'PARTIAL', 'OPEN', 'N/A')][string]$Status,
        [string]$Value = '',
        [string]$Source = 'Engineering'
    )
    $v = Limit-Text -Text $Value -Max $MaxChecklistValue
    $existing = $script:Checklist | Where-Object { $_.Id -eq $Id }
    if ($existing) {
        $existing.Status = $Status
        $existing.Value  = $v
        if ($PSBoundParameters.ContainsKey('Source')) { $existing.Source = $Source }
        return
    }
    [void]$script:Checklist.Add([PSCustomObject]@{ Id = $Id; Status = $Status; Value = $v; Source = $Source })
}

function Initialize-Checklist {
    <#
        Registers EVERY checklist ID up front so a merged site checklist is
        complete with no missing IDs. Sections overwrite with real values.
        Source is set here for anything that cannot be answered from a host.
    #>
    [CmdletBinding()]
    param()

    Register-Checklist -Id 'CL-1.1-A' -Status 'N/A' -Value 'Not an application server'
    Register-Checklist -Id 'CL-1.1-B' -Status 'N/A' -Value 'Not a session host'
    Register-Checklist -Id 'CL-1.1-C' -Status 'N/A' -Value 'Not a virtualisation host'
    Register-Checklist -Id 'CL-1.1-D' -Status 'N/A' -Value 'Not a workstation'
    Register-Checklist -Id 'CL-1.1-E' -Status 'OPEN' -Value 'Practice platforms' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.1-F' -Status 'OPEN' -Value 'Database auth mode' -Source 'Engineering'

    Register-Checklist -Id 'CL-1.2-A' -Status 'OPEN' -Value 'Hardware identity' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.2-B' -Status 'OPEN' -Value 'OS and boot posture' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.2-C' -Status 'N/A' -Value 'Not a virtualisation host - no guest inventory'
    Register-Checklist -Id 'CL-1.2-D' -Status 'N/A' -Value 'Not a virtualisation host - no headroom to assess'
    Register-Checklist -Id 'CL-1.2-E' -Status 'OPEN' -Value 'What will host the controller at this site' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.2-F' -Status 'OPEN' -Value 'Edition join capability' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.2-G' -Status 'OPEN' -Value 'Pending reboot' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.2-H' -Status 'OPEN' -Value 'Hostname length' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.2-I' -Status 'OPEN' -Value 'OS lifecycle' -Source 'Engineering'

    Register-Checklist -Id 'CL-1.3-A' -Status 'OPEN' -Value 'Domain name decision' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.3-B' -Status 'OPEN' -Value 'Network re-addressing decision' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.3-C' -Status 'N/A' -Value 'Not a virtualisation host - no guest entitlement here'
    Register-Checklist -Id 'CL-1.3-D' -Status 'OPEN' -Value 'Production platform' -Source 'AM / client'
    Register-Checklist -Id 'CL-1.3-E' -Status 'OPEN' -Value 'Server rename in/out - default OUT' -Source 'Engineering'
    Register-Checklist -Id 'CL-1.3-F' -Status 'OPEN' -Value 'Site device count for CAL sizing' -Source 'RMM device list'
    Register-Checklist -Id 'CL-1.3-G' -Status 'OPEN' -Value 'Staff working across multiple sites' -Source 'AM / client'

    Register-Checklist -Id 'CL-2.1-A' -Status 'OPEN' -Value 'Warranty' -Source 'Vendor portal'
    Register-Checklist -Id 'CL-2.1-B' -Status 'OPEN' -Value 'Out-of-band controller' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.1-C' -Status 'OPEN' -Value 'Backup job health and last restore point' -Source 'Backup console'
    Register-Checklist -Id 'CL-2.1-D' -Status 'OPEN' -Value 'Verified test restore - performed, not queried' -Source 'Backup console'
    Register-Checklist -Id 'CL-2.1-E' -Status 'OPEN' -Value 'BitLocker' -Source 'Engineering'

    Register-Checklist -Id 'CL-2.2-A' -Status 'OPEN' -Value 'Gateway config export' -Source 'Network controller'
    Register-Checklist -Id 'CL-2.2-B' -Status 'OPEN' -Value 'DC static address outside the DHCP pool' -Source 'Network controller'
    Register-Checklist -Id 'CL-2.2-C' -Status 'OPEN' -Value 'Site-to-site tunnel and peer overlap' -Source 'Network controller'
    Register-Checklist -Id 'CL-2.2-D' -Status 'N/A' -Value 'Workstation - resolver role is a server concern'
    Register-Checklist -Id 'CL-2.2-E' -Status 'OPEN' -Value 'Cloud tenant identity boundary' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.2-F' -Status 'OPEN' -Value 'Non-server inventory' -Source 'RMM device list'

    Register-Checklist -Id 'CL-2.3-A' -Status 'OPEN' -Value 'Firewall ruleset export' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.3-B' -Status 'OPEN' -Value 'Database login inventory' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.3-C' -Status 'OPEN' -Value 'Port binding mode' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.3-D' -Status 'OPEN' -Value 'ODBC hive export' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.3-E' -Status 'OPEN' -Value 'App data paths and imaging store root' -Source 'On-site / live cfg'
    Register-Checklist -Id 'CL-2.3-F' -Status 'OPEN' -Value 'Pre-change screenshots of each app launching' -Source 'On-site / live cfg'

    Register-Checklist -Id 'CL-2.4-A' -Status 'OPEN' -Value 'Remote user list' -Source 'AM / client'
    Register-Checklist -Id 'CL-2.4-B' -Status 'OPEN' -Value 'How each remote user connects' -Source 'AM / client'
    Register-Checklist -Id 'CL-2.4-C' -Status 'OPEN' -Value 'Sign-in format now and after' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.4-D' -Status 'OPEN' -Value 'Saved credentials and connection files' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.4-E' -Status 'OPEN' -Value 'Tunnel authentication destination' -Source 'Engineering'
    Register-Checklist -Id 'CL-2.4-F' -Status 'OPEN' -Value 'Advance written notice with the new sign-in format' -Source 'AM / client'
    Register-Checklist -Id 'CL-2.4-G' -Status 'OPEN' -Value 'Follow-up assisted sign-in engagement' -Source 'AM / client'

    Register-Checklist -Id 'CL-2.5-A' -Status 'OPEN' -Value 'Operating hours and hard no-touch dates' -Source 'AM / client'
    Register-Checklist -Id 'CL-2.5-B' -Status 'OPEN' -Value 'Window count and shape' -Source 'Dispatch'
    Register-Checklist -Id 'CL-2.5-C' -Status 'N/A' -Value 'Not a session host - no RDS CAL position here'

    Register-Checklist -Id 'CL-3-ALL' -Status 'N/A' -Value 'Standing constraints are acknowledgements - see the checklist, Section 3'
}

function Test-ServiceAccountProfile {
    <#
        SQLTELEMETRY$<instance>, MSSQLFDLauncher$<instance> and similar resolve
        to NT SERVICE principals, so the local-account lookup returns 'not local'
        and activity falls through to LastUseTime - the unreliable signal. Three
        such entries appeared on a move list as if they were people.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Account)
    $short = $Account.Split('\')[-1]
    if ($Account -like 'NT SERVICE\*') { return $true }
    if ($short -like '*$') { return $true }
    if ($short -match $ServiceProfilePattern) { return $true }
    return $false
}

function Add-RefHost {
    [CmdletBinding()]
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $clean = $Name.Trim().TrimStart('\').Split('\')[0].Split('/')[0].Split(',')[0]
    if ([string]::IsNullOrWhiteSpace($clean)) { return }
    if ($clean -eq $env:COMPUTERNAME) { return }
    if ($clean -match '^\d{1,3}(\.\d{1,3}){3}$') { return }
    if ($clean -eq '.' -or $clean -eq 'localhost') { return }
    # SQL Anywhere CommLinks protocol keywords are not hostnames.
    if ($clean -match '^(TCPIP|TCP|SHMEM|SharedMemory|NamedPipes|NP|HTTP|HTTPS|TLS|ALL)$') { return }
    if ($script:RefHosts -notcontains $clean) { [void]$script:RefHosts.Add($clean) }
}

function Get-CommLinkHost {
    [CmdletBinding()]
    param([string]$CommLinks)
    if ([string]::IsNullOrWhiteSpace($CommLinks)) { return $null }
    if ($CommLinks -match 'HOST\s*=\s*([^;\)\s,]+)') { return $Matches[1] }
    return $null
}

function Get-RegValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { Write-Verbose ("Get-RegValue $Path\$Name : " + $_.Exception.Message); return $null }
}

function Get-VirtualisationPlatform {
    <#
        DEFECT FIXED IN 2.5.1. The prior fallback tested whether vmicheartbeat
        EXISTED. Integration Services ship in-box since 8.1 / 2012 R2, so the
        service exists stopped on physical machines and the test always passed.
        Field result: 13 of 13 devices at one site, including a physical
        PowerEdge T360 Hyper-V HOST, classified as guests with real Dell service
        tags labelled hypervisor GUIDs.

        The guest-side key HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\
        Parameters is created by the integration components only when running AS
        a guest - absent on a Hyper-V host and on physical hardware.

        HypervisorPresent is unused: it reports true on a Hyper-V HOST as well
        as a guest and cannot distinguish them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ComputerSystem)

    $signature = "$($ComputerSystem.Manufacturer) $($ComputerSystem.Model)"
    $verdict   = 'Physical'
    $evidence  = 'no guest signature in manufacturer/model'

    switch -Regex ($signature) {
        'Microsoft Corporation.*Virtual Machine' { $verdict = 'Hyper-V guest';    $evidence = 'manufacturer/model'; break }
        'VMware'                                 { $verdict = 'VMware guest';     $evidence = 'manufacturer/model'; break }
        'innotek|VirtualBox'                     { $verdict = 'VirtualBox guest'; $evidence = 'manufacturer/model'; break }
        'QEMU|KVM'                               { $verdict = 'KVM/QEMU guest';   $evidence = 'manufacturer/model'; break }
        '\bXen\b'                                { $verdict = 'Xen guest';        $evidence = 'manufacturer/model'; break }
        'Parallels'                              { $verdict = 'Parallels guest';  $evidence = 'manufacturer/model'; break }
        'Amazon EC2'                             { $verdict = 'EC2 guest';        $evidence = 'manufacturer/model'; break }
        'Google Compute Engine'                  { $verdict = 'GCE guest';        $evidence = 'manufacturer/model'; break }
        'Nutanix'                                { $verdict = 'Nutanix guest';    $evidence = 'manufacturer/model'; break }
    }

    if ($verdict -eq 'Physical') {
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters') {
            $verdict  = 'Hyper-V guest'
            $evidence = 'guest integration registry key'
        }
    }

    return [PSCustomObject]@{ Platform = $verdict; Evidence = $evidence }
}

function Get-DirectorySizeSafe {
    <#
        Reparse-safe recursive size. Get-ChildItem -Recurse follows the legacy
        profile junctions - Application Data -> AppData\Roaming and the
        self-referential AppData\Local\Application Data -> AppData\Local -
        re-counting bytes until MAX_PATH. Field result: 350+ GB profiles on
        118 GB volumes. -Attributes !ReparsePoint filters output, not traversal.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [int]$MaxDepth = 24)

    $result = [PSCustomObject]@{ Bytes = [long]0; FileCount = 0; SkippedLinks = 0; AccessDenied = 0; DepthCapped = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $stack = New-Object System.Collections.Stack
    $stack.Push([PSCustomObject]@{ Dir = $Path; Depth = 0 })

    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($node.Depth -ge $MaxDepth) { $result.DepthCapped++; continue }

        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($node.Dir) }
        catch [System.UnauthorizedAccessException] { $result.AccessDenied++; continue }
        catch { Write-Verbose ("Enumerate $($node.Dir) : " + $_.Exception.Message); continue }

        foreach ($entry in $entries) {
            try {
                $attr = [System.IO.File]::GetAttributes($entry)
                if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { $result.SkippedLinks++; continue }
                if ($attr -band [System.IO.FileAttributes]::Directory) {
                    $stack.Push([PSCustomObject]@{ Dir = $entry; Depth = ($node.Depth + 1) })
                } else {
                    $result.Bytes += (New-Object System.IO.FileInfo($entry)).Length
                    $result.FileCount++
                }
            } catch { Write-Verbose ("Stat $entry : " + $_.Exception.Message) }
        }
    }
    return $result
}

function Resolve-ProfileAccount {
    <#
        When Translate() fails on a deleted account the caller previously kept
        the raw SID, which never matched the local-account prefix test, so the
        lookup returned 'not local' and the profile fell through to LastUseTime.
        Deleted-account profiles could be counted active and land on the move list.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Sid)

    $out = [PSCustomObject]@{ Account = $Sid; Translated = $false; Enabled = $null; LastLogon = $null; State = 'unresolved' }

    try {
        $out.Account    = (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value
        $out.Translated = $true
    } catch { Write-Verbose ("SID translate failed for $Sid : " + $_.Exception.Message) }

    if (-not $out.Translated) {
        if ($Sid -match '^S-1-5-21-') { $out.State = 'ORPHANED' } else { $out.State = 'unresolved SID' }
        return $out
    }

    if ($out.Account -notlike "$env:COMPUTERNAME\*") { $out.State = 'not local'; return $out }

    $shortName = $out.Account.Split('\')[-1]
    $acct = $null
    try { $acct = Get-LocalUser -Name $shortName -ErrorAction Stop }
    catch { Write-Verbose ("Get-LocalUser $shortName : " + $_.Exception.Message) }

    if (-not $acct) {
        try {
            $acct = Get-CimInstance -ClassName Win32_UserAccount -Filter ("LocalAccount=True AND Name='" + $shortName.Replace("'", "''") + "'") -ErrorAction Stop | Select-Object -First 1
            if ($acct) {
                $out.Enabled = (-not $acct.Disabled)
                $out.State   = if ($acct.Disabled) { 'DISABLED' } else { 'Enabled' }
                return $out
            }
        } catch { Write-Verbose ("CIM lookup $shortName : " + $_.Exception.Message) }
        $out.State = 'ORPHANED'
        return $out
    }

    $out.Enabled   = $acct.Enabled
    $out.LastLogon = $acct.LastLogon
    $out.State     = if ($acct.Enabled) { 'Enabled' } else { 'DISABLED' }
    return $out
}

function Get-PendingRebootState {
    <# A pending reboot BLOCKS a domain join. #>
    [CmdletBinding()]
    param()
    $reasons = @()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS RebootPending' }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WU RebootRequired' }
    $pfro = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
    if ($pfro -and @($pfro).Count -gt 0) { $reasons += ('PendingFileRename (' + @($pfro).Count + ')') }
    $cn = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'NV Hostname'
    $an = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'Hostname'
    if ($cn -and $an -and ($cn -ne $an)) { $reasons += 'Pending computer rename' }
    return $reasons
}

function Get-BitLockerState {
    <# Key VALUES are never read or emitted - only protector types. #>
    [CmdletBinding()]
    param()
    $vols = New-Object System.Collections.ArrayList
    try {
        foreach ($v in (Get-BitLockerVolume -ErrorAction Stop)) {
            $prot = ''
            try { $prot = (($v.KeyProtector | ForEach-Object { $_.KeyProtectorType }) -join '/') } catch { $prot = 'unreadable' }
            [void]$vols.Add([PSCustomObject]@{ Mount = $v.MountPoint; Status = $v.ProtectionStatus; Percent = $v.EncryptionPercentage; Protectors = $prot; Method = $v.EncryptionMethod })
        }
        return $vols
    } catch { Write-Verbose ('Get-BitLockerVolume unavailable: ' + $_.Exception.Message) }

    try {
        $raw = & manage-bde.exe -status 2>$null
        if ($raw) {
            $cur = $null
            foreach ($line in $raw) {
                if ($line -match 'Volume\s+([A-Za-z]:)') {
                    if ($cur) { [void]$vols.Add($cur) }
                    $cur = [PSCustomObject]@{ Mount = $Matches[1]; Status = 'unknown'; Percent = ''; Protectors = 'manage-bde'; Method = '' }
                }
                if ($cur -and $line -match 'Protection Status:\s*(.+)$')    { $cur.Status  = $Matches[1].Trim() }
                if ($cur -and $line -match 'Percentage Encrypted:\s*(.+)$') { $cur.Percent = $Matches[1].Trim() }
            }
            if ($cur) { [void]$vols.Add($cur) }
        }
    } catch { Write-Verbose ('manage-bde unavailable: ' + $_.Exception.Message) }
    return $vols
}

function Get-OsLifecycleState {
    <# A DC cannot be promoted on an EoL OS. Unlisted returns 'not assessed'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Caption)

    $now = Get-Date; $eol = $null; $label = 'not assessed'
    switch -Regex ($Caption) {
        'Server 2008'    { $eol = [datetime]'2020-01-14'; break }
        'Server 2012 R2' { $eol = [datetime]'2023-10-10'; break }
        'Server 2012'    { $eol = [datetime]'2023-10-10'; break }
        'Server 2016'    { $eol = [datetime]'2027-01-12'; break }
        'Server 2019'    { $eol = [datetime]'2029-01-09'; break }
        'Server 2022'    { $eol = [datetime]'2031-10-14'; break }
        'Server 2025'    { $eol = [datetime]'2034-10-10'; break }
        'Windows 7'      { $eol = [datetime]'2020-01-14'; break }
        'Windows 8'      { $eol = [datetime]'2023-01-10'; break }
        'Windows 10'     { $eol = [datetime]'2025-10-14'; break }
        'Windows 11'     { $label = 'supported (build-dependent)'; break }
    }
    if ($null -eq $eol) { return [PSCustomObject]@{ Eol = $null; Label = $label; Expired = $false; Soon = $false } }

    $expired = ($now -gt $eol)
    $soon    = (-not $expired -and ($now -gt $eol.AddDays(-365)))
    $label   = if ($expired) { 'END OF SUPPORT ' + $eol.ToString('yyyy-MM-dd') }
               elseif ($soon) { 'approaching EoL ' + $eol.ToString('yyyy-MM-dd') }
               else { 'supported to ' + $eol.ToString('yyyy-MM-dd') }
    return [PSCustomObject]@{ Eol = $eol; Label = $label; Expired = $expired; Soon = $soon }
}

function Get-AuditSqlInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerSpec)

    $result = [PSCustomObject]@{ WindowsLogins = $null; Databases = $null; Error = $null }
    $conn = $null
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$ServerSpec;Database=master;Integrated Security=True;Connect Timeout=5;Application Name=ReadinessAudit"
        $conn.Open()

        $logins = New-Object System.Collections.ArrayList
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 15
        $cmd.CommandText = "SELECT name, type_desc, is_disabled FROM sys.server_principals WHERE type IN ('U','G') ORDER BY name"
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            [void]$logins.Add([PSCustomObject]@{ Name = $reader.GetString(0); TypeDesc = $reader.GetString(1); Disabled = $reader.GetBoolean(2) })
        }
        $reader.Close()
        $result.WindowsLogins = $logins

        $dbs = New-Object System.Collections.ArrayList
        $cmd2 = $conn.CreateCommand()
        $cmd2.CommandTimeout = 15
        $cmd2.CommandText = @"
SELECT d.name AS db_name, d.state_desc, mf.physical_name
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.database_id > 4 AND mf.type = 0
ORDER BY d.name
"@
        $reader2 = $cmd2.ExecuteReader()
        while ($reader2.Read()) {
            [void]$dbs.Add([PSCustomObject]@{ Name = $reader2.GetString(0); State = $reader2.GetString(1); PhysicalName = $reader2.GetString(2) })
        }
        $reader2.Close()
        $result.Databases = $dbs
        return $result
    } catch {
        $result.Error = $_.Exception.Message
        Write-Verbose ("SQL query $ServerSpec : " + $_.Exception.Message)
        return $result
    } finally { if ($conn) { $conn.Dispose() } }
}

function Get-PathActivity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [int]$Days = 30)
    $out = [PSCustomObject]@{ Exists = $false; LastWrite = $null; RecentCount = 0; TotalTop = 0 }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $out }
        $out.Exists    = $true
        $out.LastWrite = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LastWriteTime
        $cutoff = (Get-Date).AddDays(-$Days)
        $top = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        $out.TotalTop    = $top.Count
        $out.RecentCount = @($top | Where-Object { $_.LastWriteTime -gt $cutoff }).Count
        return $out
    } catch { Write-Verbose ("Path activity $Path : " + $_.Exception.Message); return $out }
}

function Invoke-AuditSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    Add-DetailSection $Name
    try { & $Body } catch {
        Add-Detail ('  !! SECTION FAILED: ' + $_.Exception.Message)
        Add-Flag ("Audit section '" + $Name + "' failed - capture that section manually")
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {

    $script:Mutex = New-Object System.Threading.Mutex($false, "Global\$ScriptTag")
    try { $script:MutexHeld = $script:Mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { Write-Verbose 'Recovered abandoned mutex.'; $script:MutexHeld = $true }
    if (-not $script:MutexHeld) {
        Write-Output 'Another instance is already running on this host. Exiting.'
        Write-Output $CompleteToken
        $script:ExitCode = 0
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
        Get-ChildItem -LiteralPath $LogDir -Filter "$ScriptTag-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $LogRetention |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $logFile = Join-Path $LogDir ("$ScriptTag-{0}-{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -Path $logFile -Force | Out-Null
        $script:Transcribing = $true
    } catch { Write-Verbose ('Transcript unavailable: ' + $_.Exception.Message) }

    if ($DoCapture) {
        try { if (-not (Test-Path -LiteralPath $CaptureDir)) { New-Item -Path $CaptureDir -ItemType Directory -Force | Out-Null } }
        catch { Write-Verbose ('Capture dir unavailable: ' + $_.Exception.Message); $DoCapture = $false }
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction SilentlyContinue | Out-Null
    }

    Initialize-Checklist

    $script:AllProfiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special })

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $isServerOS = ($os.ProductType -ne 1)
    $isDC       = ($cs.DomainRole -eq 4 -or $cs.DomainRole -eq 5)
    $isHyperV   = $false
    $isRDSH     = $false
    if ($isServerOS) {
        try {
            $feat = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed }
            $isHyperV = [bool]($feat | Where-Object { $_.Name -eq 'Hyper-V' })
            $isRDSH   = [bool]($feat | Where-Object { $_.Name -eq 'RDS-RD-Server' })
        } catch { Write-Verbose ('Role enumeration unavailable: ' + $_.Exception.Message) }
    }

    $virtInfo       = Get-VirtualisationPlatform -ComputerSystem $cs
    $virtPlatform   = $virtInfo.Platform
    $isVirtualGuest = ($virtPlatform -ne 'Physical')

    if ($isVirtualGuest -and $cs.Manufacturer -match $PhysicalOem) {
        Add-Flag ("CLASSIFICATION CONFLICT: '" + $virtPlatform + "' via " + $virtInfo.Evidence + " but manufacturer '" + $cs.Manufacturer + "' is a physical OEM. Verify before trusting warranty and out-of-band lines.")
    }

    $roleParts = @()
    if ($isServerOS) { $roleParts += 'ServerOS' } else { $roleParts += 'Workstation' }
    if ($isDC)     { $roleParts += 'DomainController' }
    if ($isHyperV) { $roleParts += 'Hyper-V Host' }
    if ($isRDSH)   { $roleParts += 'RD Session Host' }
    $roleParts += $virtPlatform
    $roleText = $roleParts -join ' / '

    $provides = @()
    if ($isHyperV) { $provides += 'Hypervisor (DC can host here)' }
    if ($isRDSH)   { $provides += 'Session host' }
    if ($isServerOS -and -not $isHyperV -and -not $isRDSH -and -not $isDC) { $provides += 'Application server' }
    if (-not $isServerOS) { $provides += 'Workstation' }
    if ($isDC) { $provides += 'Existing domain controller' }
    $script:HostProvides = ($provides -join ' + ')

    $auditStamp = ('{0} | {1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    if ($isRDSH)         { Register-Checklist -Id 'CL-1.1-B' -Status 'CAPTURED' -Value ('Session host audited: ' + $auditStamp) }
    if ($isHyperV)       { Register-Checklist -Id 'CL-1.1-C' -Status 'CAPTURED' -Value ('Hypervisor audited: ' + $auditStamp) }
    if ($isServerOS -and -not $isHyperV -and -not $isRDSH) { Register-Checklist -Id 'CL-1.1-A' -Status 'CAPTURED' -Value ('App server audited: ' + $auditStamp) }
    if (-not $isServerOS) { Register-Checklist -Id 'CL-1.1-D' -Status 'CAPTURED' -Value ('Workstation audited: ' + $auditStamp) }

    # =======================================================================
    # HARDWARE IDENTITY
    # =======================================================================
    Invoke-AuditSection -Name 'Hardware Identity' -Body {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
        $mem  = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        $arr  = Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1

        $ramGb   = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 0)
        $maxGb   = if ($arr -and $arr.MaxCapacityEx) { [math]::Round(($arr.MaxCapacityEx / 1MB), 0) } else { 'unknown' }
        $cpuName = if ($cpus.Count -gt 0) { $cpus[0].Name.Trim() } else { 'unknown' }
        $cores   = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $logical = $cs.NumberOfLogicalProcessors
        $serial  = if ($bios) { $bios.SerialNumber } else { 'unknown' }

        Add-DetailKv 'Platform'      ('{0}   (evidence: {1})' -f $virtPlatform, $virtInfo.Evidence)
        Add-DetailKv 'Host provides' $script:HostProvides
        Add-DetailKv 'Manufacturer'  $cs.Manufacturer
        Add-DetailKv 'Model'         $cs.Model
        Add-DetailKv 'BIOS version'  $(if ($bios) { $bios.SMBIOSBIOSVersion } else { 'unknown' })
        Add-DetailKv 'CPU'           $cpuName
        Add-DetailKv 'Sockets/Cores' ('{0} socket(s), {1} physical, {2} logical' -f $cpus.Count, $cores, $logical)

        $bootMode = 'unknown'
        try {
            $bootMode = if ($env:firmware_type) { $env:firmware_type }
                        elseif (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' }
                        else { 'Legacy/BIOS' }
        } catch { Write-Verbose ('Firmware probe failed: ' + $_.Exception.Message) }

        $secureBoot = 'n/a'
        try { $secureBoot = [string](Confirm-SecureBootUEFI -ErrorAction Stop) }
        catch { Write-Verbose ('Confirm-SecureBootUEFI unavailable: ' + $_.Exception.Message) }

        $tpmText = 'not captured'
        try {
            $tpm = Get-Tpm -ErrorAction Stop
            $tpmText = ('Present={0} Ready={1}' -f $tpm.TpmPresent, $tpm.TpmReady)
        } catch {
            Write-Verbose ('Get-Tpm unavailable: ' + $_.Exception.Message)
            try {
                $t = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop | Select-Object -First 1
                if ($t) { $tpmText = ('Present=True Enabled={0}' -f $t.IsEnabled_InitialValue) }
            } catch { Write-Verbose ('Win32_Tpm unavailable: ' + $_.Exception.Message) }
        }

        Add-DetailKv 'Boot firmware' $bootMode
        Add-DetailKv 'Secure Boot'   $secureBoot
        Add-DetailKv 'TPM'           $tpmText
        $script:BootPosture = ('{0}/SB={1}/{2}' -f $bootMode, $secureBoot, $tpmText)

        if ($isVirtualGuest) {
            Add-DetailKv 'BIOS serial'   ('{0}  (hypervisor-assigned, not a service tag)' -f $serial)
            Add-DetailKv 'RAM allocated' ("$ramGb GB")
            Register-Checklist -Id 'CL-1.2-A' -Status 'CAPTURED' -Value ('{0} | {1} | {2}C/{3}T | {4} GB alloc' -f $virtPlatform, $cs.Model, $cores, $logical, $ramGb)
            Register-Checklist -Id 'CL-2.1-A' -Status 'N/A' -Value ($virtPlatform + ' - warranty applies to the virtualisation host')
            Register-Checklist -Id 'CL-2.1-B' -Status 'N/A' -Value 'Virtual guest - no out-of-band controller'
        } else {
            Add-DetailKv 'Service tag'   $serial
            Add-DetailKv 'RAM installed' ('{0} GB (slots {1}/{2}, max {3} GB)' -f $ramGb, $mem.Count, $(if ($arr) { $arr.MemoryDevices } else { '?' }), $maxGb)
            Register-Checklist -Id 'CL-1.2-A' -Status 'CAPTURED' -Value ('{0} {1} | tag {2} | {3}C/{4}T | {5} GB' -f $cs.Manufacturer, $cs.Model, $serial, $cores, $logical, $ramGb)
            if ($serial -and $serial -ne 'unknown') {
                Register-Checklist -Id 'CL-2.1-A' -Status 'OPEN' -Value ('Warranty lookup - tag ' + $serial) -Source 'Vendor portal'
            }
            Register-Checklist -Id 'CL-2.1-B' -Status 'OPEN' -Value 'Out-of-band controller reachability and licence' -Source 'Engineering'
        }

        Add-Detail ''
        foreach ($vol in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
            $freeGb = [math]::Round(($vol.FreeSpace / 1GB), 1)
            $script:VolumeUsed[$vol.DeviceID] = ($vol.Size - $vol.FreeSpace)
            Add-Detail ('  Volume {0} : {1} GB free of {2} GB' -f $vol.DeviceID, $freeGb, [math]::Round(($vol.Size / 1GB), 1))
            if ($isServerOS -and $freeGb -lt 15) {
                Add-Flag ("DISK: volume $($vol.DeviceID) has only $freeGb GB free on this server - insufficient for a profile transfer or join. Expand or clean before cutover.")
                Add-Worklist ("DISK EXPANSION: $($vol.DeviceID) at $freeGb GB free")
            }
        }
    }

    # =======================================================================
    # BITLOCKER
    # =======================================================================
    Invoke-AuditSection -Name 'BitLocker  (key escrow must be planned before the join)' -Body {
        $bl = Get-BitLockerState
        if (@($bl).Count -eq 0) {
            Add-Detail '  (no BitLocker volumes reported, or BitLocker unavailable)'
            Register-Checklist -Id 'CL-2.1-E' -Status 'CAPTURED' -Value 'No BitLocker-protected volumes'
            return
        }
        $protected = @()
        foreach ($v in $bl) {
            Add-Detail ('  {0,-6} Protection={1,-10} Encrypted={2,-6} Method={3,-14} Protectors={4}' -f $v.Mount, $v.Status, $v.Percent, $v.Method, $v.Protectors)
            if ("$($v.Status)" -match 'On|1') { $protected += $v.Mount }
        }
        if ($protected.Count -gt 0) {
            Add-Flag ('BITLOCKER: ' + ($protected -join ',') + ' protected with local-only keys. Capture to IT Glue BEFORE the join and escrow to AD after - an encrypted endpoint joined without key custody is a recovery incident.')
            Add-Worklist ('BITLOCKER KEY CUSTODY: ' + ($protected -join ',') + ' - IT Glue pre-join, AD escrow post-join')
            Register-Checklist -Id 'CL-2.1-E' -Status 'PARTIAL' -Value ('Protected: ' + ($protected -join ',') + ' - local-only keys, escrow plan required')
        } else {
            Register-Checklist -Id 'CL-2.1-E' -Status 'CAPTURED' -Value 'BitLocker present, protection off'
        }
    }

    # =======================================================================
    # IDENTITY / DOMAIN STATE
    # =======================================================================
    Invoke-AuditSection -Name 'Identity / Domain State' -Body {
        Add-DetailKv 'Computer name'      $env:COMPUTERNAME
        Add-DetailKv 'Domain / Workgroup' $cs.Domain
        Add-DetailKv 'PartOfDomain'       $cs.PartOfDomain
        Add-DetailKv 'DomainRole'         ('{0}  (0/1=wkstn 2=standalone 3=member 4/5=DC)' -f $cs.DomainRole)
        Add-DetailKv 'OS'                 $os.Caption
        Add-DetailKv 'Version / Build'    $os.Version
        Add-DetailKv 'OS install date'    $os.InstallDate
        Add-DetailKv 'Last boot'          $os.LastBootUpTime

        $bp = if (Get-Variable -Name BootPosture -Scope Script -ErrorAction SilentlyContinue) { $script:BootPosture } else { 'not captured' }
        Register-Checklist -Id 'CL-1.2-B' -Status 'CAPTURED' -Value ('{0} b{1} | {2} | {3}' -f $os.Caption, $os.Version, $cs.Domain, $bp)

        $life = Get-OsLifecycleState -Caption $os.Caption
        Add-DetailKv 'OS lifecycle' $life.Label
        if ($life.Expired) {
            Add-Flag ('OS END OF SUPPORT: ' + $os.Caption + ' ended ' + $life.Eol.ToString('yyyy-MM-dd') + '. A DC cannot be promoted on it; as a member it constrains the SMB and NTLM posture.')
            Add-Worklist ('OS EOL: ' + $os.Caption + ' - upgrade is a separate ticket')
        } elseif ($life.Soon) {
            Add-Flag ('OS approaching end of support: ' + $os.Caption + ' on ' + $life.Eol.ToString('yyyy-MM-dd'))
        }
        Register-Checklist -Id 'CL-1.2-I' -Status 'CAPTURED' -Value ($os.Caption + ' - ' + $life.Label)

        $nameLen = $env:COMPUTERNAME.Length
        Add-DetailKv 'Hostname length' ('{0} of 15 max (NetBIOS)' -f $nameLen)
        if ($nameLen -gt 15) {
            Add-Blocker ("HOSTNAME TOO LONG: $nameLen chars, NetBIOS truncates at 15")
            Add-Flag ("HOSTNAME: '$env:COMPUTERNAME' is $nameLen characters - NetBIOS caps at 15 and truncates, producing a name mismatch after join. Rename before joining.")
            Register-Checklist -Id 'CL-1.2-H' -Status 'CAPTURED' -Value ("BLOCKER - $nameLen chars exceeds the 15-char NetBIOS limit")
        } elseif ($nameLen -eq 15) {
            Add-Flag ("HOSTNAME: '$env:COMPUTERNAME' is exactly 15 characters - at the NetBIOS limit, no headroom.")
            Register-Checklist -Id 'CL-1.2-H' -Status 'CAPTURED' -Value ("$nameLen chars - at the NetBIOS limit")
        } else {
            Register-Checklist -Id 'CL-1.2-H' -Status 'CAPTURED' -Value ("$nameLen chars - within the NetBIOS limit")
        }

        $pending = Get-PendingRebootState
        if (@($pending).Count -gt 0) {
            Add-DetailKv 'Pending reboot' (($pending -join '; '))
            Add-Blocker ('PENDING REBOOT: ' + ($pending -join '; '))
            Add-Flag ('PENDING REBOOT (' + ($pending -join '; ') + ') - a domain join FAILS until this host is rebooted. Reboot in the pre-join window, not the cutover window.')
            Add-Worklist ('REBOOT PRE-JOIN: ' + ($pending -join '; '))
            Register-Checklist -Id 'CL-1.2-G' -Status 'CAPTURED' -Value ('BLOCKER - ' + ($pending -join '; '))
        } else {
            Add-DetailKv 'Pending reboot' 'none'
            Register-Checklist -Id 'CL-1.2-G' -Status 'CAPTURED' -Value 'No pending reboot - join not blocked'
        }

        if ($os.Caption -match '\bHome\b|\bCore\b(?! Server)|\bS Mode\b') {
            Add-Blocker ("EDITION: '" + $os.Caption + "' cannot join a domain")
            Add-Flag ("EDITION BLOCKER: '" + $os.Caption + "' cannot join a domain. A Pro/Enterprise upgrade licence is required, or this device stays out.")
            Add-Worklist ('PRO UPGRADE: ' + $os.Caption + ' cannot join a domain')
            Register-Checklist -Id 'CL-1.2-F' -Status 'CAPTURED' -Value ('BLOCKER - ' + $os.Caption + ' cannot join')
        } else {
            Register-Checklist -Id 'CL-1.2-F' -Status 'CAPTURED' -Value ($os.Caption + ' - join capable')
        }

        if (-not $cs.PartOfDomain) {
            Add-Flag ("$env:COMPUTERNAME is WORKGROUP '" + $cs.Domain + "' - full identity cutover required")
        }

        $tcpip = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        Add-DetailKv 'Primary DNS suffix' (Get-RegValue -Path $tcpip -Name 'Domain')
        Add-DetailKv 'DHCP DNS suffix'    (Get-RegValue -Path $tcpip -Name 'DhcpDomain')

        $winlogon  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $autoAdmin = Get-RegValue -Path $winlogon -Name 'AutoAdminLogon'
        $autoUser  = Get-RegValue -Path $winlogon -Name 'DefaultUserName'
        Add-DetailKv 'AutoAdminLogon'  $autoAdmin
        Add-DetailKv 'DefaultUserName' $autoUser
        if ($autoAdmin -eq '1') {
            Add-Flag ("Auto-logon ENABLED for '" + $autoUser + "' - staff do not type a password today. A domain credential is a visible workflow change; put it in the user notice.")
        }

        $currentFormat = if ($cs.PartOfDomain) { "$($cs.Domain)\username" } else { "$env:COMPUTERNAME\username" }
        Add-DetailKv 'Sign-in now'   $currentFormat
        Add-DetailKv 'Sign-in after' '<NETBIOS>\username -or- username@<domain.fqdn>'
        Register-Checklist -Id 'CL-2.4-C' -Status 'PARTIAL' -Value ('now = ' + $currentFormat + ' ; after = <NETBIOS>\username')
    }

    # =======================================================================
    # NETWORK CONFIGURATION
    # =======================================================================
    Invoke-AuditSection -Name 'Network Configuration' -Body {
        foreach ($cfg in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            if (-not $cfg.IPv4Address) { continue }
            $ipList  = ($cfg.IPv4Address | ForEach-Object { $_.IPAddress }) -join ','
            $gwList  = ($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ','
            $dnsList = ($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ','
            $prefix  = (Get-NetIPAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1).PrefixLength
            $dhcp    = (Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
            Add-Detail ('  {0,-22} IPv4={1}/{2}  GW={3}  DNS={4}  DHCP={5}' -f $cfg.InterfaceAlias, $ipList, $prefix, $gwList, $dnsList, $dhcp)
        }

        $hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
        $hostsEnt  = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*\d' })
        Add-DetailKv 'HOSTS entries' $hostsEnt.Count
        foreach ($e in $hostsEnt) {
            Add-Detail ('  hosts-entry : ' + $e.Trim())
            Add-Flag 'HOSTS file contains static entries - these mask AD DNS after join'
        }

        if ($isServerOS) {
            try {
                $dnsRole = Get-WindowsFeature -Name DNS -ErrorAction Stop
                Add-DetailKv 'DNS Server role' $(if ($dnsRole.Installed) { 'INSTALLED' } else { 'not installed' })
                if ($dnsRole.Installed) {
                    Add-Flag 'Standalone DNS Server role present - non-AD zones must be retired at cutover, not left alongside AD DNS'
                    $zoneNames = @(); $zoneLines = @()
                    try {
                        Get-DnsServerZone -ErrorAction Stop | ForEach-Object {
                            $zoneLines += ('  dns-zone : {0,-28} Type={1} AD-int={2}' -f $_.ZoneName, $_.ZoneType, $_.IsDsIntegrated)
                            $zoneNames += $_.ZoneName
                        }
                    } catch { Write-Verbose ('Zone enumeration failed: ' + $_.Exception.Message); $zoneLines += '  dns-zone : (unable to enumerate)' }
                    Add-DetailList -Items $zoneLines -Label 'zone'
                    if ($zoneNames.Count -gt 0) { Add-Worklist ('RETIRE DNS ZONES: ' + ($zoneNames -join ', ')) }
                    Register-Checklist -Id 'CL-2.2-D' -Status 'CAPTURED' -Value ('DNS role INSTALLED - ' + $zoneNames.Count + ' zone(s), retire at cutover')
                } else {
                    Register-Checklist -Id 'CL-2.2-D' -Status 'CAPTURED' -Value 'No standalone DNS role on this server'
                }
            } catch { Write-Verbose ('DNS role query failed: ' + $_.Exception.Message) }
        }
    }

    # =======================================================================
    # LOCAL ACCOUNTS
    # =======================================================================
    Invoke-AuditSection -Name 'Local Accounts' -Body {
        $localUsers = $null
        try { $localUsers = Get-LocalUser -ErrorAction Stop } catch { Write-Verbose ('Get-LocalUser unavailable: ' + $_.Exception.Message) }
        $lines = @()
        if ($localUsers) {
            foreach ($u in $localUsers) {
                $lines += ('  {0,-24} Enabled={1,-5} PwdLastSet={2,-20} LastLogon={3}' -f $u.Name, $u.Enabled, $u.PasswordLastSet, $u.LastLogon)
                if ($u.Enabled -and -not $u.PasswordLastSet -and $u.LastLogon) {
                    Add-Flag ("Local account '" + $u.Name + "' is enabled and has logged on but has no PasswordLastSet - likely blank password or PasswordNotRequired")
                }
            }
        } else {
            Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' | ForEach-Object {
                $lines += ('  {0,-24} Disabled={1}  (CIM fallback)' -f $_.Name, $_.Disabled)
            }
        }
        Add-DetailList -Items $lines -Label 'account'
    }

    # =======================================================================
    # LOCAL GROUP MEMBERSHIP
    # =======================================================================
    Invoke-AuditSection -Name 'Local Group Membership' -Body {
        $rdpMembers = New-Object System.Collections.ArrayList
        foreach ($g in @('Administrators', 'Remote Desktop Users', 'Users', 'Backup Operators', 'Power Users')) {
            $members = $null
            try { $members = Get-LocalGroupMember -Group $g -ErrorAction Stop } catch { Write-Verbose ("Get-LocalGroupMember $g : " + $_.Exception.Message) }
            if ($members) {
                foreach ($m in $members) {
                    Add-Detail ('  {0,-22} <- {1,-38} ({2})' -f $g, $m.Name, $m.ObjectClass)
                    if ($g -eq 'Remote Desktop Users') {
                        [void]$rdpMembers.Add($m.Name)
                        if ($m.Name -match '(Everyone|Authenticated Users)$') {
                            Add-Flag ("SECURITY: '" + $m.Name + "' is in Remote Desktop Users - any account that can authenticate can open a session. Route to the CISO separately.")
                        }
                    }
                }
            } else {
                try {
                    $adsi = [ADSI]("WinNT://$env:COMPUTERNAME/$g,group")
                    $adsi.psbase.Invoke('Members') | ForEach-Object {
                        $n = $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null)
                        Add-Detail ('  {0,-22} <- {1}  (ADSI)' -f $g, $n)
                        if ($g -eq 'Remote Desktop Users') { [void]$rdpMembers.Add($n) }
                    }
                } catch { Write-Verbose ("ADSI $g : " + $_.Exception.Message); Add-Detail ('  {0,-22} <- (not present)' -f $g) }
            }
        }
        $script:RdpGroupMembers = $rdpMembers
    }

    # =======================================================================
    # USER PROFILES
    # =======================================================================
    Invoke-AuditSection -Name 'User Profiles  (domain join = new SID = new profile per user)' -Body {
        Add-Detail '  ACTIVITY IS DECIDED ON ACCOUNT LastLogon, NOT profile LastUse.'
        Add-Detail '  Service-account profiles (NT SERVICE, name$) are excluded from the move list.'
        if (-not $MeasureProfiles) { Add-Detail '  (sizing skipped - AUDIT_SkipProfileSize=1)' }
        else { Add-Detail ('  Sizing measures ACTIVE profiles only (window: ' + $ProfileDays + ' days).') }

        $cutoff = (Get-Date).AddDays(-$ProfileDays)
        $total = 0; $activeAcct = 0; $activeUse = 0; $orphan = 0; $disabled = 0; $svc = 0; $sizeIssues = 0
        $lines = @()

        foreach ($p in $script:AllProfiles) {
            $total++
            $res = Resolve-ProfileAccount -Sid $p.SID

            # Service-account profiles are machinery, not people.
            if ($res.Translated -and (Test-ServiceAccountProfile -Account $res.Account)) {
                $svc++
                $lines += ('  {0,-26} SERVICE ACCOUNT - excluded from move list' -f $res.Account)
                continue
            }

            if ($res.State -eq 'ORPHANED') { $orphan++ }
            if ($res.Enabled -eq $false)   { $disabled++ }

            $isActive = $false
            $basis    = 'LastUse fallback'
            if ($res.State -eq 'ORPHANED' -or $res.State -eq 'unresolved SID') { $isActive = $false; $basis = 'ORPHANED' }
            elseif ($res.Enabled -eq $false) { $isActive = $false; $basis = 'acct DISABLED' }
            elseif ($res.LastLogon) { $isActive = ($res.LastLogon -gt $cutoff); $basis = 'acct LastLogon' }
            elseif ($p.LastUseTime) { $isActive = ($p.LastUseTime -gt $cutoff) }

            if ($isActive) { $activeAcct++ }
            if ($p.LastUseTime -and $p.LastUseTime -gt $cutoff) { $activeUse++ }

            $sizeMb = $null; $sizeText = 'not measured'
            if ($isActive -and $MeasureProfiles -and $p.LocalPath -and (Test-Path -LiteralPath $p.LocalPath)) {
                $m = Get-DirectorySizeSafe -Path $p.LocalPath
                $sizeMb = [math]::Round(($m.Bytes / 1MB), 0)
                $script:MoveBytes += $m.Bytes
                $sizeText = ('{0} MB ({1} files, {2} links skipped' -f $sizeMb, $m.FileCount, $m.SkippedLinks)
                if ($m.AccessDenied -gt 0) { $sizeText += (', {0} denied - PARTIAL' -f $m.AccessDenied); $sizeIssues++ }
                $sizeText += ')'
            }

            if ($isActive) {
                $short = if ($res.Translated) { $res.Account.Split('\')[-1] } else { 'SID:' + $p.SID.Substring([math]::Max(0, $p.SID.Length - 8)) }
                if ($null -ne $sizeMb) { [void]$script:MoveProfiles.Add(('{0}({1})' -f $short, $sizeMb)) }
                else { [void]$script:MoveProfiles.Add($short) }
                # Administrative or service-shaped names on the move list warrant
                # a human look - a prior provider's profile is active but should
                # not be transferred. The script cannot know that; it surfaces it.
                if ($short -match $AdminProfilePattern) { [void]$script:AdminProfiles.Add($short) }
            }

            $lines += ('  {0,-26} State={1,-14} AcctLogon={2,-20} Active={3,-6} ({4})' -f $res.Account, $res.State, $res.LastLogon, $isActive, $basis)
            if ($isActive -and $MeasureProfiles) { $lines += ('        size: ' + $sizeText) }
        }

        Add-DetailList -Items $lines -Label 'profile'
        Add-Detail ''
        Add-DetailKv 'Non-special profiles'    $total
        Add-DetailKv 'Service accounts'        ('{0}  (excluded)' -f $svc)
        Add-DetailKv 'ACTIVE (acct LastLogon)' ('{0}  <- these move' -f $activeAcct)
        Add-DetailKv 'LastUse within window'   ('{0}  (unreliable)' -f $activeUse)
        Add-DetailKv 'Disabled'                $disabled
        Add-DetailKv 'Orphaned (no account)'   $orphan

        if ($MeasureProfiles) {
            Add-DetailKv 'Total to move' ('{0} GB' -f [math]::Round(($script:MoveBytes / 1GB), 2))
            if ($script:VolumeUsed.ContainsKey($env:SystemDrive) -and $script:MoveBytes -gt $script:VolumeUsed[$env:SystemDrive]) {
                Add-Flag ('MEASUREMENT ERROR: profile total exceeds used space on ' + $env:SystemDrive + '. Do not scope from these sizes.')
            }
            if ($sizeIssues -gt 0) { Add-Flag "$sizeIssues profile(s) hit access-denied during sizing - those totals are PARTIAL and read low" }
        }

        $ft = "PROFILES: $activeAcct to move (of $total total, $svc service, $disabled disabled, $orphan orphaned)"
        if ($MeasureProfiles) { $ft += (', {0} GB' -f [math]::Round(($script:MoveBytes / 1GB), 2)) }
        Add-Flag $ft
        if ($script:AdminProfiles.Count -gt 0) {
            Add-Flag ('REVIEW BEFORE TRANSFER: admin/service-shaped profiles on the move list - ' + (($script:AdminProfiles | Sort-Object -Unique) -join ', ') + '. Confirm each should carry into the new domain.')
        }
        if ($activeUse -gt $activeAcct) {
            Add-Flag "$activeUse profiles show recent LastUse but their accounts are disabled, orphaned or dormant - do not scope from LastUse."
        }
        if ($orphan -gt 0) {
            Add-Flag "$orphan orphaned profile(s) - directory present, no matching account. Excluded from the move list; cleanup candidates."
        }
        $script:ProfileActive   = $activeAcct
        $script:ProfileTotal    = $total
        $script:ServiceProfiles = $svc
    }

    # =======================================================================
    # SMB SHARES
    # =======================================================================
    Invoke-AuditSection -Name 'SMB Shares, Permissions and Write Activity' -Body {
        $shares = @()
        try {
            $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { $_.Name -notmatch '^\w\$$' -and $_.Name -notin @('IPC$', 'ADMIN$', 'print$') })
        } catch { Write-Verbose ('Get-SmbShare unavailable: ' + $_.Exception.Message); Add-Detail '  (Get-SmbShare unavailable)'; return }
        if ($shares.Count -eq 0) { Add-Detail '  (no non-administrative shares)'; return }

        $reAcl = @()
        foreach ($s in $shares) {
            Add-Detail ('  SHARE {0}  ->  {1}' -f $s.Name, $s.Path)
            [void]$script:AclDump.Add(('SHARE {0} -> {1}' -f $s.Name, $s.Path))

            $act = Get-PathActivity -Path $s.Path -Days 30
            if ($act.Exists) { Add-Detail ('        activity : lastwrite={0}  entries={1}  mod<30d={2}' -f $act.LastWrite, $act.TotalTop, $act.RecentCount) }

            $needs = $false
            Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue | ForEach-Object {
                $line = ('        share-perm : {0,-38} {1} {2}' -f $_.AccountName, $_.AccessControlType, $_.AccessRight)
                Add-Detail $line
                [void]$script:AclDump.Add($line)
                if ($_.AccountName -eq 'Everyone') {
                    $needs = $true
                    Add-Flag ("Share '" + $s.Name + "' grants Everyone - re-ACL to a domain group AFTER endpoints are joined and validated, never before")
                }
                if ("$($_.AccountName)" -like "$env:COMPUTERNAME\*") {
                    $needs = $true
                    Add-Flag ("Share '" + $s.Name + "' grants LOCAL account " + $_.AccountName + " - will not resolve for domain users")
                }
            }
            if ($s.Path -and (Test-Path -LiteralPath $s.Path)) {
                try {
                    $aceLines = @()
                    (Get-Acl -LiteralPath $s.Path).Access | ForEach-Object {
                        $line = ('        ntfs-ace : {0,-38} {1} {2}' -f $_.IdentityReference, $_.AccessControlType, $_.FileSystemRights)
                        $aceLines += $line
                        [void]$script:AclDump.Add($line)
                        if ("$($_.IdentityReference)" -like "$env:COMPUTERNAME\*") {
                            $needs = $true
                            Add-Flag ('NTFS ACE on ' + $s.Path + ' references LOCAL account ' + $_.IdentityReference)
                        }
                    }
                    Add-DetailList -Items $aceLines -Label 'ACE'
                } catch { Write-Verbose ('ACL read failed: ' + $_.Exception.Message); Add-Detail '        ntfs-ace : (unreadable)' }
            }
            if ($needs) { $reAcl += $s.Name }
        }
        if ($reAcl.Count -gt 0) { Add-Worklist ('RE-ACL SHARES (' + $reAcl.Count + '): ' + ($reAcl -join ', ')) }
    }

    # =======================================================================
    # SERVICE LOGON IDENTITIES
    # =======================================================================
    Invoke-AuditSection -Name 'Service Logon Identities  (non-builtin only)' -Body {
        $builtin = @('LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService',
                     'NT AUTHORITY\LOCAL SERVICE', 'NT AUTHORITY\NETWORK SERVICE', 'NT AUTHORITY\SYSTEM')
        $custom = 0; $svcAcc = @()
        Get-CimInstance -ClassName Win32_Service | Sort-Object Name | ForEach-Object {
            $sn = $_.StartName
            if ($sn -and ($builtin -notcontains $sn)) {
                $custom++
                Add-Detail ('  {0,-36} runs-as={1,-28} State={2}' -f $_.Name, $sn, $_.State)
                # NT SERVICE\<name> virtual accounts are machine-local and survive a join.
                if ($sn -notlike 'NT SERVICE\*') {
                    Add-Flag ("Service '" + $_.Name + "' runs as '" + $sn + "' - confirm it survives domain join")
                    $svcAcc += ('{0} ({1})' -f $_.Name, $sn)
                }
            }
        }
        if ($custom -eq 0) { Add-Detail '  (all services under builtin accounts - clean)' }
        Add-Detail '  NOTE: NT SERVICE\<name> virtual accounts are machine-local and survive a join.'
        if ($svcAcc.Count -gt 0) { Add-Worklist ('SERVICE ACCOUNTS TO REVIEW: ' + ($svcAcc -join '; ')) }
    }

    # =======================================================================
    # PMS / IMAGING FOOTPRINT
    # =======================================================================
    Invoke-AuditSection -Name 'PMS / Imaging Footprint  (no data enumeration)' -Body {
        $enginePattern = 'SQLANY|SQL Anywhere|Sybase|Actian|Pervasive|MySQL|MariaDB|FairCom|ctree|c-tree|PostgreSQL|Firebird'
        $allServices = @(Get-CimInstance -ClassName Win32_Service)

        $engineLines = @()
        foreach ($svcx in ($allServices | Where-Object { $_.Name -match $enginePattern -or $_.DisplayName -match $enginePattern })) {
            $engineLines += ('  engine  {0,-36} State={1,-9} RunAs={2}' -f $svcx.Name, $svcx.State, $svcx.StartName)
            [void]$script:DbEngines.Add(('{0}={1}' -f $svcx.Name, $svcx.State))
            if ($svcx.PathName -match '\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
            if ($svcx.PathName -match '([A-Za-z]:\\[^"]*?\.db)') {
                $dbPath = $Matches[1]
                try {
                    if (Test-Path -LiteralPath $dbPath) {
                        $f = Get-Item -LiteralPath $dbPath -Force -ErrorAction Stop
                        $engineLines += ('          dbfile: {0}  {1} MB  lastwrite={2}' -f $dbPath, [math]::Round(($f.Length / 1MB), 1), $f.LastWriteTime)
                    } else { $engineLines += ('          dbfile: {0}  (NOT PRESENT)' -f $dbPath) }
                } catch { Write-Verbose ('DB stat failed: ' + $_.Exception.Message) }
            }
        }
        if ($engineLines.Count -eq 0) { Add-Detail '  engine  (none detected)' } else { Add-DetailList -Items $engineLines -Label 'engine line' }

        $platformsPresent = @()
        foreach ($platform in ($VendorMap.Keys | Sort-Object)) {
            $pattern = $VendorMap[$platform].Pattern
            $vendor  = $VendorMap[$platform].Vendor
            $svcs = @($allServices | Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern })
            $apps = @()
            foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
                    $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if ($props -and $props.DisplayName -and $props.DisplayName -match $pattern) { $apps += $props }
                }
            }
            if ($svcs.Count -eq 0 -and $apps.Count -eq 0) { continue }

            $running = @($svcs | Where-Object { $_.State -eq 'Running' }).Count
            $platformsPresent += ('{0}({1}/{2})' -f $platform, $running, $svcs.Count)

            if ($running -gt 0 -or $isServerOS) {
                $ver = if ($apps.Count -gt 0) { ($apps | Select-Object -First 1).DisplayVersion } else { '' }
                $entry = ('{0} v{1} -> {2}' -f $platform, $ver, $vendor)
                if ($script:Vendors -notcontains $entry) { [void]$script:Vendors.Add($entry) }
            }

            Add-Detail ''
            Add-Detail ('  PLATFORM {0}   vendor: {1}   services {2} ({3} running)   products {4}' -f $platform, $vendor, $svcs.Count, $running, $apps.Count)
            foreach ($svcy in ($svcs | Sort-Object Name)) {
                Add-Detail ('        svc  {0,-36} State={1,-9} RunAs={2}' -f $svcy.Name, $svcy.State, $svcy.StartName)
                if ($svcy.PathName -match '\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
            }
            foreach ($app in ($apps | Sort-Object DisplayName -Unique)) {
                Add-Detail ('        app  {0,-44} v{1}' -f $app.DisplayName, $app.DisplayVersion)
                if ($app.InstallLocation -and (Test-Path -LiteralPath $app.InstallLocation)) {
                    $a = Get-PathActivity -Path $app.InstallLocation -Days 30
                    if ($a.Exists) { Add-Detail ('             loc: {0}  lastwrite={1}  mod<30d={2}' -f $app.InstallLocation, $a.LastWrite, $a.RecentCount) }
                }
            }
        }

        if ($platformsPresent.Count -eq 0) {
            Register-Checklist -Id 'CL-1.1-E' -Status 'CAPTURED' -Value 'No practice platform on this host'
            Register-Checklist -Id 'CL-1.3-D' -Status 'N/A' -Value 'No practice platform on this host'
        } else {
            $engText = if ($script:DbEngines.Count -gt 0) { (($script:DbEngines | Sort-Object -Unique) -join '; ') } else { 'none' }
            Register-Checklist -Id 'CL-1.1-E' -Status 'CAPTURED' -Value (($platformsPresent -join '; ') + ' | eng: ' + $engText)
            if ($platformsPresent.Count -gt 1) {
                Register-Checklist -Id 'CL-1.3-D' -Status 'PARTIAL' -Value ('Multiple: ' + ($platformsPresent -join '; ') + ' - confirm production') -Source 'AM / client'
                Add-Flag ('More than one practice platform detected (' + ($platformsPresent -join '; ') + ') - confirm which is production')
            } else {
                Register-Checklist -Id 'CL-1.3-D' -Status 'CAPTURED' -Value ('Single: ' + ($platformsPresent -join '; '))
            }
        }
    }

    # =======================================================================
    # SQL INSTANCES
    # =======================================================================
    Invoke-AuditSection -Name 'SQL Instances, Authentication, Ports, Logins' -Body {
        $root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        if (-not (Test-Path -LiteralPath $root)) {
            Add-Detail '  (no SQL Server instances)'
            Register-Checklist -Id 'CL-1.1-F' -Status 'CAPTURED' -Value 'No SQL Server instances on this host'
            Register-Checklist -Id 'CL-2.3-B' -Status 'N/A' -Value 'No SQL instances - no login inventory'
            Register-Checklist -Id 'CL-2.3-C' -Status 'N/A' -Value 'No SQL instances - no port binding'
            return
        }
        $key = Get-Item -LiteralPath $root
        $authSummary = @(); $loginsToFix = @(); $portModes = @(); $loginInv = @()
        foreach ($inst in $key.GetValueNames()) {
            $id        = $key.GetValue($inst)
            $setupKey  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\Setup"
            $engineKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\MSSQLServer"
            $tcpKey    = "$engineKey\SuperSocketNetLib\Tcp\IPAll"

            $edition   = Get-RegValue -Path $setupKey  -Name 'Edition'
            $version   = Get-RegValue -Path $setupKey  -Name 'Version'
            $loginMode = Get-RegValue -Path $engineKey -Name 'LoginMode'
            $tcpPort   = Get-RegValue -Path $tcpKey    -Name 'TcpPort'
            $dynPort   = Get-RegValue -Path $tcpKey    -Name 'TcpDynamicPorts'

            $modeText = switch ($loginMode) { 1 { 'Windows Auth ONLY' } 2 { 'Mixed Mode' } default { 'unknown' } }
            if ($inst -eq 'MSSQLSERVER') { $svcName = 'MSSQLSERVER'; $spec = '.' } else { $svcName = "MSSQL`$$inst"; $spec = ".\$inst" }
            $svcq = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $svcName + "'") -ErrorAction SilentlyContinue

            $portMode = if (-not [string]::IsNullOrWhiteSpace("$tcpPort")) { "static $tcpPort" }
                        elseif (-not [string]::IsNullOrWhiteSpace("$dynPort")) { "DYNAMIC $dynPort" }
                        else { 'not configured' }
            $portModes += ('{0}={1}' -f $inst, $portMode)

            Add-Detail ''
            Add-Detail ('  INSTANCE {0}   {1}   v{2}' -f $inst, $edition, $version)
            Add-Detail ('        auth : {0} (LoginMode={1})   port : {2}' -f $modeText, $loginMode, $portMode)
            if ($svcq) { Add-Detail ('        service : {0}  State={1}  RunAs={2}' -f $svcq.Name, $svcq.State, $svcq.StartName) }

            $authSummary += ('{0}={1}' -f $inst, $modeText)
            [void]$script:DbAuth.Add(('{0}={1}' -f $inst, $modeText))

            if ([string]::IsNullOrWhiteSpace("$tcpPort") -and -not [string]::IsNullOrWhiteSpace("$dynPort")) {
                Add-Flag ("SQL instance '" + $inst + "' uses a DYNAMIC port - scope the firewall rule to the program, not the port, or it breaks at the next service restart")
                Add-Worklist ("SQL DYNAMIC PORT: '" + $inst + "' - firewall rule must be program-scoped")
            }
            if ($loginMode -eq 1) {
                Add-Flag ("SQL instance '" + $inst + "' is Windows-Auth ONLY - existing logins break at domain join")
                Add-Worklist ("SQL WINDOWS-AUTH ONLY: '" + $inst + "' - logins re-created against domain principals")
            }

            if ($svcq -and $svcq.State -eq 'Running') {
                $info = Get-AuditSqlInfo -ServerSpec $spec
                if ($info.Error) {
                    Add-Detail ('        win-logins: (query failed - ' + $info.Error + ')')
                    $loginInv += ('{0}=failed' -f $inst)
                } else {
                    $loginInv += ('{0}={1} win' -f $inst, @($info.WindowsLogins).Count)
                    if (@($info.WindowsLogins).Count -eq 0) {
                        Add-Detail '        win-logins: (none - all SQL-authenticated; clean across a join)'
                    } else {
                        $ll = @()
                        foreach ($login in $info.WindowsLogins) {
                            $ll += ('        win-login : {0,-42} {1,-14} Disabled={2}' -f $login.Name, $login.TypeDesc, $login.Disabled)
                            if ($login.Name -like "$env:COMPUTERNAME\*") {
                                Add-Flag ("SQL login '" + $login.Name + "' on '" + $inst + "' references a LOCAL principal - will not resolve after domain join")
                                $loginsToFix += ('{0}\{1}' -f $inst, $login.Name)
                            }
                            if ($login.Name -eq 'BUILTIN\Administrators') {
                                Add-Flag ("SQL instance '" + $inst + "' grants BUILTIN\Administrators - after join this silently widens to every Domain Admin.")
                                $loginsToFix += ('{0}\BUILTIN\Admins' -f $inst)
                            }
                        }
                        Add-DetailList -Items $ll -Label 'login'
                    }
                    foreach ($db in $info.Databases) {
                        $stamp = 'not reachable'
                        try {
                            if (Test-Path -LiteralPath $db.PhysicalName) {
                                $f = Get-Item -LiteralPath $db.PhysicalName -Force -ErrorAction Stop
                                $stamp = ('{0} MB, lastwrite {1}' -f [math]::Round(($f.Length / 1MB), 1), $f.LastWriteTime)
                            }
                        } catch { Write-Verbose ('DB stat failed: ' + $_.Exception.Message) }
                        Add-Detail ('        database : {0,-24} {1,-10} {2}' -f $db.Name, $db.State, $stamp)
                    }
                }
            }
        }
        Register-Checklist -Id 'CL-1.1-F' -Status 'CAPTURED' -Value ($authSummary -join ' | ')
        Register-Checklist -Id 'CL-2.3-B' -Status 'CAPTURED' -Value (($loginInv -join ' | ') + ' - list in transcript')
        Register-Checklist -Id 'CL-2.3-C' -Status 'CAPTURED' -Value ($portModes -join ' | ')
        if ($loginsToFix.Count -gt 0) { Add-Worklist ('SQL LOGINS TO RE-CREATE (' + $loginsToFix.Count + '): ' + ($loginsToFix -join '; ')) }
    }

    # =======================================================================
    # ODBC DATA SOURCES
    # =======================================================================
    Invoke-AuditSection -Name 'ODBC Data Sources' -Body {
        $hives = New-Object System.Collections.ArrayList
        [void]$hives.Add('HKLM:\SOFTWARE\ODBC\ODBC.INI')
        [void]$hives.Add('HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI')
        Get-ChildItem -LiteralPath 'HKU:\' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'S-1-5-21' -and $_.Name -notmatch '_Classes$' } |
            ForEach-Object { [void]$hives.Add(($_.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', 'Registry::') + '\SOFTWARE\ODBC\ODBC.INI')) }
        $n = 0; $lines = @()
        foreach ($hive in $hives) {
            $srcKey = Join-Path $hive 'ODBC Data Sources'
            if (-not (Test-Path -LiteralPath $srcKey)) { continue }
            $sk = Get-Item -LiteralPath $srcKey
            foreach ($dsn in $sk.GetValueNames()) {
                $n++
                $driver = $sk.GetValue($dsn)
                $d = Get-ItemProperty -LiteralPath (Join-Path $hive $dsn) -ErrorAction SilentlyContinue
                $server = $null; $db = $null; $trusted = $null; $cl = $null
                if ($d) {
                    foreach ($c in @('Server', 'ServerName')) { if (-not $server -and $d.$c) { $server = $d.$c } }
                    $cl = $d.CommLinks
                    if (-not $server -and $cl) { $server = Get-CommLinkHost -CommLinks $cl }
                    foreach ($c in @('Database', 'DatabaseName')) { if (-not $db -and $d.$c) { $db = $d.$c } }
                    $trusted = $d.Trusted_Connection
                }
                $lines += ('  DSN {0,-20} driver={1,-26} server={2,-16} trusted={3}' -f $dsn, $driver, $server, $trusted)
                if ($cl) { $lines += ('      commlinks: ' + $cl + '  (protocol spec, not a hostname)') }
                Add-RefHost $server
                if ($trusted -eq 'Yes') { Add-Flag ("ODBC DSN '" + $dsn + "' uses Trusted_Connection - the calling identity changes at domain join") }
            }
        }
        Add-DetailList -Items $lines -Label 'DSN'
        if ($n -eq 0) { Add-Detail '  (no DSNs found)' }
        Add-Detail '  NOTE: per-user DSNs are visible only while that user hive is loaded.'
        Register-Checklist -Id 'CL-2.3-D' -Status $(if ($DoCapture) { 'CAPTURED' } else { 'PARTIAL' }) -Value ("$n DSN(s)" + $(if ($DoCapture) { '; exported' } else { '; set AUDIT_CaptureDir to export' }))
    }

    # =======================================================================
    # SCHEDULED TASKS
    # =======================================================================
    Invoke-AuditSection -Name 'Scheduled Tasks with Non-System Principals' -Body {
        $sysP = '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE|S-1-5-18|S-1-5-19|S-1-5-20|Users|Administrators|INTERACTIVE|Authenticated Users)$'
        $n = 0; $lines = @()
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
            $pr = $_.Principal
            if ($pr.UserId -and $pr.UserId -notmatch $sysP) {
                $n++
                $lines += ('  {0,-44} RunAs={1,-22} LogonType={2}' -f ($_.TaskPath + $_.TaskName), $pr.UserId, $pr.LogonType)
                if ($pr.LogonType -eq 'Password') {
                    Add-Flag ('Scheduled task ' + $_.TaskName + ' stores a password for ' + $pr.UserId + ' - must be re-created post-join')
                }
            }
        }
        Add-DetailList -Items $lines -Label 'task'
        if ($n -eq 0) { Add-Detail '  (none)' }
    }

    # =======================================================================
    # MAPPED DRIVES
    # =======================================================================
    Invoke-AuditSection -Name 'Persistent Mapped Drives  (per loaded user hive)' -Body {
        $n = 0; $lines = @()
        Get-ChildItem -LiteralPath 'HKU:\' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'S-1-5-21' -and $_.Name -notmatch '_Classes$' } |
            ForEach-Object {
                $sid = Split-Path $_.Name -Leaf
                $netKey = $_.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', 'Registry::') + '\Network'
                if (Test-Path -LiteralPath $netKey) {
                    $who = $sid
                    try { $who = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value }
                    catch { Write-Verbose ('SID translate failed: ' + $_.Exception.Message) }
                    Get-ChildItem -LiteralPath $netKey -ErrorAction SilentlyContinue | ForEach-Object {
                        $n++
                        $rp = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).RemotePath
                        $lines += ('  {0,-26} {1}: -> {2}' -f $who, (Split-Path $_.Name -Leaf), $rp)
                        if ($rp -match '^\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
                    }
                }
            }
        Add-DetailList -Items $lines -Label 'mapping'
        if ($n -eq 0) { Add-Detail '  (none in loaded hives)' }
    }

    # =======================================================================
    # PRINTERS
    # =======================================================================
    Invoke-AuditSection -Name 'Printers / Ports' -Body {
        $lines = @(); $shared = @()
        Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            $lines += ('  {0,-30} Shared={1,-6} Port={2,-24} Driver={3}' -f $_.Name, $_.Shared, $_.PortName, $_.DriverName)
            if ($_.PortName -match '^\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
            if ($_.Shared) {
                Add-Flag ('Printer ' + $_.Name + ' is shared from this host - re-deploy via GPO after join')
                $shared += $_.Name
            }
        }
        Add-DetailList -Items $lines -Label 'printer'
        if ($lines.Count -eq 0) { Add-Detail '  (none)' }
        if ($shared.Count -gt 0) { Add-Worklist ('SHARED PRINTERS TO GPO-DEPLOY: ' + ($shared -join ', ')) }
    }

    # =======================================================================
    # SMB / NTLM POSTURE
    # =======================================================================
    Invoke-AuditSection -Name 'SMB / NTLM Posture' -Body {
        $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
        Add-DetailKv 'LmCompatibilityLevel' (Get-RegValue -Path $lsa -Name 'LmCompatibilityLevel')
        Add-DetailKv 'RestrictSendingNTLM'  (Get-RegValue -Path "$lsa\MSV1_0" -Name 'RestrictSendingNTLMTraffic')
        $ss = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
        if ($ss) {
            Add-DetailKv 'SMB1 enabled' $ss.EnableSMB1Protocol
            Add-DetailKv 'Server signing required' $ss.RequireSecuritySignature
            if ($ss.EnableSMB1Protocol) { Add-Flag 'SMB1 is ENABLED server-side - remediate before or during the domain build' }
        }
        Add-Detail '  NOTE: Get-SmbClientConfiguration does NOT surface LmCompatibilityLevel. The LSA value is authoritative.'
    }

    # =======================================================================
    # FIREWALL PROFILES
    # =======================================================================
    Invoke-AuditSection -Name 'Windows Firewall  (domain join activates the Domain profile)' -Body {
        Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object {
            Add-Detail ('  {0,-10} Enabled={1,-6} InboundDefault={2}' -f $_.Name, $_.Enabled, $_.DefaultInboundAction)
        }
        $inb  = @(Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue)
        $priv = @($inb | Where-Object { $_.Profile -eq 'Private' })
        Add-DetailKv 'Enabled inbound rules' $inb.Count
        Add-DetailKv 'Private-only rules'    $priv.Count

        if ($priv.Count -gt 0) {
            Add-Detail '  --- Private-only rules; these go inert at domain join ---'
            Add-DetailList -Items @($priv | Sort-Object DisplayName | ForEach-Object { '  private-only : ' + $_.DisplayName }) -Label 'rule'
            Add-Flag ($priv.Count.ToString() + ' inbound firewall rule(s) are Private-profile only - they go inert at join. Re-scope BEFORE any post-join application test.')
            # Only servers carry rules worth naming; workstation rules are stock Windows entries.
            if ($isServerOS) {
                $names = @($priv | Sort-Object DisplayName -Unique | Select-Object -First 5)
                $wl = ('RE-SCOPE FIREWALL (' + $priv.Count + '): ' + ($names -join '; '))
                if ($priv.Count -gt 5) { $wl += ('; +' + ($priv.Count - 5) + ' in transcript') }
                Add-Worklist $wl
            }
        }
        Add-DetailKv 'Active profile' ((Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory)
        Register-Checklist -Id 'CL-2.3-A' -Status $(if ($DoCapture) { 'CAPTURED' } else { 'PARTIAL' }) -Value ("$($priv.Count) private-only rule(s)" + $(if ($DoCapture) { '; exported' } else { '; set AUDIT_CaptureDir to export' }))
    }

    # =======================================================================
    # REMOTE ACCESS SURFACE
    # =======================================================================
    Invoke-AuditSection -Name 'Remote Access Surface' -Body {
        $tsKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $rdpTcp = "$tsKey\WinStations\RDP-Tcp"
        $deny   = Get-RegValue -Path $tsKey -Name 'fDenyTSConnections'
        $rdpOn  = ($deny -eq 0)
        Add-DetailKv 'RDP enabled'  $(if ($rdpOn) { 'Yes' } elseif ($null -eq $deny) { 'unknown' } else { 'No' })
        Add-DetailKv 'RDP port'     (Get-RegValue -Path $rdpTcp -Name 'PortNumber')
        Add-DetailKv 'NLA required' (Get-RegValue -Path $rdpTcp -Name 'UserAuthentication')

        $vpnPat = 'OpenVPN|WireGuard|FortiClient|GlobalProtect|AnyConnect|Cisco VPN|SonicWall|NetExtender|Pulse Secure|Ivanti|ZeroTier|Tailscale|Meraki|WatchGuard|SoftEther|Barracuda|Splashtop|TeamViewer|ScreenConnect|AnyDesk|LogMeIn|Aeroadmin|RustDesk|Chrome Remote'
        $vpnLines = @(); $vpnFound = @()
        foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($p -and $p.DisplayName -and $p.DisplayName -match $vpnPat) {
                    $vpnLines += ('  remote-client : {0,-40} v{1}' -f $p.DisplayName, $p.DisplayVersion)
                    $vpnFound += $p.DisplayName
                }
            }
        }
        Add-DetailList -Items ($vpnLines | Sort-Object -Unique) -Label 'client'
        if ($vpnLines.Count -eq 0) { Add-Detail '  remote-client : (none detected)' }

        if ($vpnFound.Count -gt 0) {
            $uniq = ($vpnFound | Sort-Object -Unique) -join ', '
            Register-Checklist -Id 'CL-2.4-E' -Status 'PARTIAL' -Value ('Tunnel client(s): ' + $uniq)
            Add-Worklist ('TUNNEL AUTH DECISION: ' + $uniq)
            Add-Flag ('Remote-access client(s) installed: ' + $uniq + '. Confirm each is MSP-managed; unmanaged remote tooling on a practice server is a security finding, not a domain-project item.')
        } else {
            Register-Checklist -Id 'CL-2.4-E' -Status 'CAPTURED' -Value 'No tunnel/remote-access client on this host'
        }

        $credTotal = 0; $rdpTotal = 0; $credLines = @()
        foreach ($p in $script:AllProfiles) {
            if (-not $p.LocalPath -or -not (Test-Path -LiteralPath $p.LocalPath)) { continue }
            $who = $p.SID
            try { $who = (New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value }
            catch { Write-Verbose ('SID translate failed: ' + $_.Exception.Message) }
            $cc = 0
            foreach ($cp in @((Join-Path $p.LocalPath 'AppData\Roaming\Microsoft\Credentials'),
                              (Join-Path $p.LocalPath 'AppData\Local\Microsoft\Credentials'))) {
                if (Test-Path -LiteralPath $cp) { $cc += @(Get-ChildItem -LiteralPath $cp -Force -File -ErrorAction SilentlyContinue).Count }
            }
            $rc = @(Get-ChildItem -LiteralPath $p.LocalPath -Filter '*.rdp' -Recurse -Force -File -Depth 3 -ErrorAction SilentlyContinue).Count
            if ($cc -gt 0 -or $rc -gt 0) {
                $credLines += ('  {0,-28} saved-creds={1,-4} rdp-files={2}' -f $who, $cc, $rc)
                $credTotal += $cc; $rdpTotal += $rc
            }
        }
        Add-Detail ''
        Add-Detail '  --- saved credentials and .rdp files (counts only; nothing read) ---'
        Add-DetailList -Items $credLines -Label 'profile'
        if ($credLines.Count -eq 0) { Add-Detail '  (none found)' }
        Add-DetailKv 'Saved credentials' $credTotal
        Add-DetailKv 'Saved .rdp files'  $rdpTotal
        if ($credTotal -gt 0 -or $rdpTotal -gt 0) {
            Add-Flag ("Saved credentials ($credTotal) and/or .rdp files ($rdpTotal) here - stale entries produce a post-cutover sign-in failure that looks like an outage")
        }
        Register-Checklist -Id 'CL-2.4-D' -Status 'CAPTURED' -Value ("creds=$credTotal ; rdp=$rdpTotal across $($credLines.Count) profile(s)")

        $rdu = @()
        if (Get-Variable -Name RdpGroupMembers -Scope Script -ErrorAction SilentlyContinue) { $rdu = @($script:RdpGroupMembers) }
        if ($rdpOn) {
            Add-Flag 'RDP is enabled here - every remote user sign-in name changes at join. Advance notice and an assisted first sign-in are required.'
            Register-Checklist -Id 'CL-2.4-A' -Status 'PARTIAL' -Value ("RDP on. RDU members: $($rdu.Count) - list in transcript") -Source 'AM / client'
        } else {
            Register-Checklist -Id 'CL-2.4-A' -Status 'CAPTURED' -Value 'RDP not enabled on this host'
        }
    }

    # =======================================================================
    # RDS CONFIGURATION
    # =======================================================================
    if ($isRDSH) {
        Invoke-AuditSection -Name 'RDS Configuration' -Body {
            $tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
            $mode  = Get-RegValue -Path "$tsKey\RCM\Licensing Core" -Name 'LicensingMode'
            $modeText = switch ($mode) { 2 { 'Per Device' } 4 { 'Per User' } 5 { 'Not configured' } default { 'not set / grace' } }
            Add-DetailKv 'Licensing mode' ('{0} (raw={1})' -f $modeText, $mode)
            Add-DetailKv 'LicenseServers (GPO)' (Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'LicenseServers')

            $graceDays = $null
            try {
                $ts = Get-CimInstance -Namespace 'root/cimv2/TerminalServices' -ClassName Win32_TerminalServiceSetting -ErrorAction Stop
                Add-DetailKv 'WMI LicensingName' $ts.LicensingName
                $g = Invoke-CimMethod -InputObject $ts -MethodName GetGracePeriodDays -ErrorAction SilentlyContinue
                if ($g -and $null -ne $g.DaysLeft) { $graceDays = $g.DaysLeft }
            } catch { Write-Verbose ('TerminalServices WMI unavailable: ' + $_.Exception.Message) }

            $inGrace = Test-Path -LiteralPath "$tsKey\RCM\GracePeriod"
            Add-DetailKv 'Grace key present' $inGrace
            Add-DetailKv 'Grace days left'   $(if ($null -ne $graceDays) { $graceDays } else { 'not captured' })

            if ($inGrace) {
                $gt = if ($null -ne $graceDays) { " $graceDays day(s) left." } else { ' Days left not captured.' }
                Add-Flag ('RDS LICENSING: serving users on the grace clock, not licensed CALs.' + $gt + ' When grace expires, connections stop.')
                Add-Worklist ('RDS CALs REQUIRED: grace active, ' + $(if ($null -ne $graceDays) { "$graceDays days left" } else { 'days unknown' }))
                if ($null -ne $graceDays -and $graceDays -le 14) {
                    Add-Blocker ("RDS GRACE EXPIRING: $graceDays day(s) - remote access stops when it expires")
                }
            }
            if ($mode -ne 2 -and $mode -ne 4) {
                Add-Flag 'RDS licensing mode NOT configured. Per-User CALs require a directory; a workgroup host can only run Per-Device.'
            }
            $sessions = @(& quser.exe 2>$null | Select-Object -Skip 1)
            Add-DetailKv 'Active sessions' $sessions.Count
            Register-Checklist -Id 'CL-2.5-C' -Status 'PARTIAL' -Value ("mode=$modeText ; grace=$inGrace ; days=$(if ($null -ne $graceDays) { $graceDays } else { 'n/c' }) ; sessions=$($sessions.Count)")
        }
    }

    # =======================================================================
    # HYPER-V
    # =======================================================================
    if ($isHyperV) {
        Invoke-AuditSection -Name 'Hyper-V Inventory and Licensing Entitlement' -Body {
            $vms = @()
            try { $vms = @(Get-VM -ErrorAction Stop) } catch {
                Write-Verbose ('Hyper-V module unavailable: ' + $_.Exception.Message)
                Add-Detail '  (Hyper-V module unavailable)'
                return
            }
            $assigned = 0
            foreach ($vm in ($vms | Sort-Object Name)) {
                $gb = [math]::Round(($vm.MemoryAssigned / 1GB), 1)
                $assigned += $gb
                Add-Detail ('  {0,-18} State={1,-9} Gen={2} vCPU={3,-3} RAM={4} GB  Dyn={5}' -f $vm.Name, $vm.State, $vm.Generation, $vm.ProcessorCount, $gb, $vm.DynamicMemoryEnabled)
            }
            $phys     = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 1)
            $headroom = [math]::Round(($phys - $assigned), 1)
            $logCpu   = $cs.NumberOfLogicalProcessors
            $asgCpu   = ($vms | Measure-Object -Property ProcessorCount -Sum).Sum

            Add-Detail ''
            Add-DetailKv 'Host RAM'     ("$phys GB")
            Add-DetailKv 'Assigned'     ("$assigned GB")
            Add-DetailKv 'Headroom'     ("$headroom GB")
            Add-DetailKv 'vCPU asg/log' ("$asgCpu / $logCpu")

            if ($asgCpu -ge $logCpu) { Add-Flag ("vCPU at or over subscription ($asgCpu of $logCpu logical) - a controller guest increases contention") }
            if ($headroom -lt 8)     { Add-Flag ("RAM headroom is $headroom GB - a controller guest needs 4-8 GB. Confirm the fit.") }

            Register-Checklist -Id 'CL-1.2-C' -Status 'CAPTURED' -Value (($vms | ForEach-Object { '{0}({1}GB/{2}c,{3})' -f $_.Name, [math]::Round(($_.MemoryAssigned / 1GB), 1), $_.ProcessorCount, $_.State }) -join ' ')
            Register-Checklist -Id 'CL-1.2-D' -Status 'CAPTURED' -Value ("headroom $headroom GB of $phys GB ; vCPU $asgCpu of $logCpu")

            $dcFit = if ($headroom -ge 8) { 'fits comfortably' } elseif ($headroom -ge 4) { 'tight but workable' } else { 'DOES NOT FIT - expand RAM first' }
            Register-Checklist -Id 'CL-1.2-E' -Status 'CAPTURED' -Value ("Controller hosts here - $dcFit ($headroom GB free)")
            if ($headroom -lt 4) { Add-Blocker ("NO ROOM FOR CONTROLLER: only $headroom GB RAM headroom") }

            $guests = $vms.Count
            if ($os.Caption -match 'Datacenter') {
                $verdict = 'Datacenter - unlimited guests, no additional licence'
            } elseif ($os.Caption -match 'Standard') {
                if ($guests -ge 2) {
                    $verdict = "Standard: 2 entitled, $guests in use. Controller is #$($guests + 1) - REQUIRES an additional Server Standard licence or Datacenter conversion."
                    Add-Flag 'LICENSING: Standard host, both guest entitlements consumed. A controller guest requires an additional Server Standard licence or Datacenter conversion. Mandatory quote line.'
                    Add-Worklist 'SERVER LICENCE REQUIRED: controller guest exceeds Standard entitlement'
                } else {
                    $verdict = "Standard: 2 entitled, $guests in use. Controller fits but needs its own key."
                }
            } else {
                $verdict = "Edition '$($os.Caption)' - entitlement not determined, verify manually"
            }
            Add-Detail ''
            Add-Detail ('  ENTITLEMENT: ' + $verdict)
            Register-Checklist -Id 'CL-1.3-C' -Status 'CAPTURED' -Value $verdict

            Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object {
                Add-Detail ('  vswitch {0,-18} Type={1}  AllowMgmtOS={2}' -f $_.Name, $_.SwitchType, $_.AllowManagementOS)
            }
        }
    }

    # =======================================================================
    # ACTIVATION + TIME + REFERENCED HOSTS
    # =======================================================================
    Invoke-AuditSection -Name 'Windows Activation' -Body {
        Get-CimInstance -ClassName SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Windows*' } | ForEach-Object {
                $st = switch ($_.LicenseStatus) {
                    0 { 'Unlicensed' } 1 { 'Licensed' } 2 { 'OOB Grace' } 3 { 'OOT Grace' }
                    4 { 'Non-Genuine' } 5 { 'Notification' } 6 { 'Extended Grace' } default { 'unknown' }
                }
                Add-Detail ('  {0}' -f $_.Name)
                Add-Detail ('       Status={0}  Channel={1}  KeyLast5={2}' -f $st, $_.ProductKeyChannel, $_.PartialProductKey)
                if ($st -ne 'Licensed') { Add-Flag ('ACTIVATION: Windows reports ' + $st + ' on this host - resolve before or during the build') }
            }
    }

    Invoke-AuditSection -Name 'Time Source' -Body {
        $w32 = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
        Add-DetailKv 'w32tm source' (& w32tm.exe /query /source 2>&1)
        Add-DetailKv 'NtpServer'    (Get-RegValue -Path $w32 -Name 'NtpServer')
        Add-DetailKv 'Type'         (Get-RegValue -Path $w32 -Name 'Type')
    }

    Invoke-AuditSection -Name 'Referenced Hostnames - Resolution Test' -Body {
        if ($script:RefHosts.Count -eq 0) { Add-Detail '  (none referenced)'; return }
        foreach ($h in ($script:RefHosts | Sort-Object)) {
            $res = 'FAILED'
            try {
                $r = Resolve-DnsName -Name $h -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1
                if ($r) { $res = $r.IPAddress }
            } catch { Write-Verbose ("Resolve $h : " + $_.Exception.Message) }
            Add-Detail ('  {0,-22} -> {1}' -f $h, $res)
            if ($res -eq 'FAILED') {
                Add-Flag ("Referenced host '" + $h + "' does not resolve via DNS - depends on NetBIOS/WINS today and behaves differently after AD DNS cutover")
            }
        }
    }

    # =======================================================================
    # OPTIONAL STATE CAPTURE
    # =======================================================================
    if ($DoCapture) {
        Invoke-AuditSection -Name 'State Capture  (rollback reference)' -Body {
            $stamp = '{0}-{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
            $fw = Join-Path $CaptureDir "firewall-$stamp.wfw"
            try { & netsh.exe advfirewall export "$fw" | Out-Null; Add-Detail ('  firewall : ' + $fw) }
            catch { Write-Verbose ('Firewall export failed: ' + $_.Exception.Message); Add-Detail '  firewall : FAILED' }

            foreach ($pair in @(
                @{ Key = 'HKLM\SOFTWARE\ODBC\ODBC.INI';             File = "odbc-64-$stamp.reg" },
                @{ Key = 'HKLM\SOFTWARE\WOW6432Node\ODBC\ODBC.INI'; File = "odbc-32-$stamp.reg" })) {
                $t = Join-Path $CaptureDir $pair.File
                try { & reg.exe export $pair.Key "$t" /y | Out-Null; Add-Detail ('  odbc : ' + $t) }
                catch { Write-Verbose ('ODBC export failed: ' + $_.Exception.Message); Add-Detail '  odbc : FAILED' }
            }

            if ($script:AclDump.Count -gt 0) {
                $af = Join-Path $CaptureDir "share-acl-$stamp.txt"
                try { $script:AclDump | Set-Content -LiteralPath $af -Encoding UTF8; Add-Detail ('  share-acl : ' + $af) }
                catch { Write-Verbose ('ACL dump failed: ' + $_.Exception.Message); Add-Detail '  share-acl : FAILED' }
            }
        }
    }

    # No hypervisor here - if no host at the site reports one, CL-1.2-E stays
    # OPEN across the site, which is the signal the build needs tailoring.
    if (-not $isHyperV) {
        Register-Checklist -Id 'CL-1.2-E' -Status 'OPEN' -Value 'No hypervisor here - document what hosts the controller at this site' -Source 'Engineering'
    }

    # =======================================================================
    # BYTE-BUDGETED EMISSION WITH RESERVED FLOORS
    # =======================================================================
    $script:Enc     = [System.Text.Encoding]::UTF8
    $script:Emitted = New-Object System.Collections.ArrayList
    $script:Used    = 0
    $ceiling        = $OutputBudget - 600

    $dropScope = 0; $dropChk = 0; $dropWork = 0; $dropFlag = 0; $dropDet = 0
    $dropSections = New-Object System.Collections.ArrayList

    function Add-Emit {
        param([string]$Line, [int]$Limit)
        $need = $script:Enc.GetByteCount($Line) + 2
        if (($script:Used + $need) -gt $Limit) { return $false }
        [void]$script:Emitted.Add($Line)
        $script:Used += $need
        return $true
    }

    [void](Add-Emit '========================================================================' $ceiling)
    [void](Add-Emit ' WORKGROUP -> DOMAIN READINESS AUDIT  (read-only)' $ceiling)
    [void](Add-Emit (' Client   : ' + $ClientLabel) $ceiling)
    [void](Add-Emit (' Host     : ' + $env:COMPUTERNAME) $ceiling)
    [void](Add-Emit (' Role     : ' + $roleText) $ceiling)
    [void](Add-Emit (' Provides : ' + $script:HostProvides) $ceiling)
    [void](Add-Emit (' Ticket   : ' + $TicketLabel) $ceiling)
    [void](Add-Emit (' Run      : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) $ceiling)
    [void](Add-Emit (' Version  : ' + $ScriptVersion) $ceiling)
    [void](Add-Emit (' Flags    : ' + $script:Flags.Count) $ceiling)
    if ($DoCapture) { [void](Add-Emit (' Capture  : ' + $CaptureDir) $ceiling) }
    [void](Add-Emit '========================================================================' $ceiling)

    # -- MIGRATION SCOPE. Vendors before profile names: the vendor list is short
    #    and bounded, the name list is neither. On a 19-profile app server the
    #    names consumed the allowance and the vendor block never emitted.
    $limScope = $ceiling - ($FloorChecklist + $FloorWorklist + $FloorFlags)
    [void](Add-Emit '' $limScope)
    [void](Add-Emit '== MIGRATION SCOPE ==' $limScope)
    [void](Add-Emit '' $limScope)

    if ($script:Blockers.Count -gt 0) {
        [void](Add-Emit '  ** DOMAIN JOIN BLOCKERS **' $limScope)
        foreach ($b in $script:Blockers) { if (-not (Add-Emit ('    ! ' + $b) $limScope)) { $dropScope++ } }
        [void](Add-Emit '' $limScope)
    }

    if ($script:Vendors.Count -gt 0) {
        [void](Add-Emit '  VENDORS TO CONTACT (domain-join support statement):' $limScope)
        foreach ($v in ($script:Vendors | Sort-Object -Unique)) { if (-not (Add-Emit ('    - ' + $v) $limScope)) { $dropScope++ } }
        [void](Add-Emit '' $limScope)
    }
    if ($script:DbEngines.Count -gt 0) {
        [void](Add-Emit ('  DB ENGINES : ' + (($script:DbEngines | Sort-Object -Unique) -join ' | ')) $limScope)
    }
    if ($script:DbAuth.Count -gt 0) {
        [void](Add-Emit ('  SQL AUTH   : ' + (($script:DbAuth | Sort-Object -Unique) -join ' | ')) $limScope)
    }
    if ($script:DbEngines.Count -gt 0 -or $script:DbAuth.Count -gt 0) { [void](Add-Emit '' $limScope) }

    $moveGb = [math]::Round(($script:MoveBytes / 1GB), 2)
    if ($MeasureProfiles) {
        [void](Add-Emit ('  PROFILES TO MOVE : {0} of {1} total ({2} service excluded), {3} GB' -f $script:ProfileActive, $script:ProfileTotal, $script:ServiceProfiles, $moveGb) $limScope)
    } else {
        [void](Add-Emit ('  PROFILES TO MOVE : {0} of {1} total ({2} service excluded)' -f $script:ProfileActive, $script:ProfileTotal, $script:ServiceProfiles) $limScope)
    }
    if ($script:MoveProfiles.Count -gt 0) {
        $buf = @(); $emittedNames = 0
        foreach ($mp in $script:MoveProfiles) {
            $buf += $mp
            if ($buf.Count -eq 3) {
                if (Add-Emit ('    ' + ($buf -join '  ')) $limScope) { $emittedNames += 3 } else { $dropScope++ }
                $buf = @()
            }
        }
        if ($buf.Count -gt 0) {
            if (Add-Emit ('    ' + ($buf -join '  ')) $limScope) { $emittedNames += $buf.Count } else { $dropScope++ }
        }
        if ($script:MoveProfiles.Count -gt $emittedNames) {
            [void](Add-Emit ('    (+{0} more in transcript)' -f ($script:MoveProfiles.Count - $emittedNames)) $limScope)
        }
    }

    # -- CHECKLIST ----------------------------------------------------------
    $limChk = $ceiling - ($FloorWorklist + $FloorFlags)
    [void](Add-Emit '' $limChk)
    [void](Add-Emit '== CHECKLIST AUTO-FILL  (all checklist IDs) ==' $limChk)
    [void](Add-Emit '' $limChk)

    $openBySource = @{}
    foreach ($item in ($script:Checklist | Sort-Object Id)) {
        if ($item.Status -eq 'OPEN') {
            if (-not $openBySource.ContainsKey($item.Source)) { $openBySource[$item.Source] = @() }
            $openBySource[$item.Source] += $item.Id
            continue
        }
        if (-not (Add-Emit ('  {0,-11}{1,-9} {2}' -f $item.Id, $item.Status, $item.Value) $limChk)) { $dropChk++ }
    }

    if ($openBySource.Keys.Count -gt 0) {
        [void](Add-Emit '' $limChk)
        [void](Add-Emit '== MANUAL CAPTURE REQUIRED  (not discoverable from a host) ==' $limChk)
        [void](Add-Emit '' $limChk)
        foreach ($src in ($openBySource.Keys | Sort-Object)) {
            $ids = $openBySource[$src] -join ' '
            if (-not (Add-Emit ('  {0,-19}: {1}' -f $src, $ids) $limChk)) { $dropChk++ }
        }
    }

    # -- WORKLIST -----------------------------------------------------------
    $limWork = $ceiling - $FloorFlags
    if ($script:Worklist.Count -gt 0) {
        [void](Add-Emit '' $limWork)
        [void](Add-Emit '== CUTOVER WORKLIST ==' $limWork)
        [void](Add-Emit '' $limWork)
        foreach ($w in $script:Worklist) { if (-not (Add-Emit ('  * ' + $w) $limWork)) { $dropWork++ } }
    }

    # -- FLAGS --------------------------------------------------------------
    [void](Add-Emit '' $ceiling)
    [void](Add-Emit '== MIGRATION FLAGS ==' $ceiling)
    [void](Add-Emit '' $ceiling)
    if ($script:Flags.Count -eq 0) {
        [void](Add-Emit '  (no flags raised)' $ceiling)
    } else {
        $i = 0
        foreach ($f in $script:Flags) {
            $i++
            if (-not (Add-Emit ('  [{0:D2}] {1}' -f $i, $f) $ceiling)) { $dropFlag++ }
        }
    }

    # -- DETAIL -------------------------------------------------------------
    $hdr = $false; $curSec = ''
    $starts = @{}
    foreach ($s in $script:SectionIndex) { $starts[$s.Start] = $s.Name }

    for ($idx = 0; $idx -lt $script:Detail.Count; $idx++) {
        if ($starts.ContainsKey($idx)) { $curSec = $starts[$idx] }
        if (-not $hdr) {
            if (-not (Add-Emit '' $ceiling)) { break }
            [void](Add-Emit '======================================================================' $ceiling)
            [void](Add-Emit ' FULL DETAIL' $ceiling)
            [void](Add-Emit '======================================================================' $ceiling)
            $hdr = $true
        }
        if (-not (Add-Emit $script:Detail[$idx] $ceiling)) {
            $dropDet++
            if ($curSec -and $dropSections -notcontains $curSec) { [void]$dropSections.Add($curSec) }
        }
    }

    foreach ($line in $script:Emitted) { Write-Output $line }
    Write-Output ''
    if (($dropScope + $dropChk + $dropWork + $dropFlag) -gt 0) {
        Write-Output ('-- BUDGET: HIGH-VALUE CONTENT OMITTED at {0} of {1} bytes --' -f $script:Used, $OutputBudget)
        if ($dropScope -gt 0) { Write-Output ('-- {0} scope line(s) omitted --' -f $dropScope) }
        if ($dropChk   -gt 0) { Write-Output ('-- {0} checklist line(s) omitted --' -f $dropChk) }
        if ($dropWork  -gt 0) { Write-Output ('-- {0} worklist line(s) omitted --' -f $dropWork) }
        if ($dropFlag  -gt 0) { Write-Output ('-- {0} flag(s) omitted --' -f $dropFlag) }
    }
    if ($dropDet -gt 0) {
        $sn = if ($dropSections.Count -gt 0) { $dropSections -join ', ' } else { 'unnamed' }
        if ($sn.Length -gt 95) { $sn = $sn.Substring(0, 95) + '...' }
        Write-Output ('-- detail truncated ({0} lines) from: {1} --' -f $dropDet, $sn)
    }
    if (($dropScope + $dropChk + $dropWork + $dropFlag + $dropDet) -eq 0) {
        Write-Output ('-- Complete: {0} of {1} bytes, nothing omitted --' -f $script:Used, $OutputBudget)
    }
    Write-Output ('-- Full report: ' + $LogDir + '\' + $ScriptTag + '-' + $env:COMPUTERNAME + '-*.log --')
    Write-Output ('END - ' + $env:COMPUTERNAME + ' - ' + $script:Flags.Count + ' flag(s)')
    Write-Output $CompleteToken

    # NinjaOne treats any non-zero exit as FAILURE. Flags are the normal case, so
    # flag count must NOT drive the exit code - it is already in the banner and
    # the END line. Non-zero is reserved for a genuine script error.
    $script:ExitCode = 0

} catch {
    Write-Output ''
    Write-Output '!! AUDIT ERROR - report is INCOMPLETE and must not be treated as authoritative'
    Write-Output ('!! ' + $_.Exception.Message)
    if ($_.InvocationInfo) {
        Write-Output ('!! at line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim())
    }
    $script:ExitCode = 1
    Write-Output $CompleteToken
} finally {
    if ($script:MutexHeld -and $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { Write-Verbose ('Mutex release: ' + $_.Exception.Message) }
        $script:Mutex.Dispose()
    }
    if ($script:Transcribing) {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose ('Stop-Transcript: ' + $_.Exception.Message) }
    }
}

exit $script:ExitCode