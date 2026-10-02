<#
.SYNOPSIS
    Repairs a Veeam Agent for Windows installation whose MSI registration is
    broken, so the backup server can push an upgrade to it again.

.DESCRIPTION
    WHY: a Veeam B&R server upgrading its managed agents runs the new MSI on
    the endpoint, which must first uninstall the old version. When the old
    version's cached installer package is missing or its registration is
    damaged, that uninstall fails and the whole push fails with:

      Package installation result: is success: False (code: 1603)
      Error 1714. The older version of Veeam Agent for Microsoft Windows
      cannot be removed. Contact your technical support group.

    Veeam setup then refuses to upgrade the BACKUP SERVER at all while an
    outdated agent is registered ("Outdated Veeam Agents", severity error), so
    one broken endpoint blocks its whole BDR. Confirmed on <WORKSTATION01>
    (agent 6.0.0.960) blocking <SERVER01>, 2026-09-25.

    THIS RUNS ON THE ENDPOINT, NOT THE BDR. The backup server can only push
    Veeam packages; it cannot repair a Windows Installer database on another
    machine. NinjaOne can, because it has its own agent there.

    WHAT IT DOES, in order, stopping at the first success:
      1. Reads every Veeam Agent entry in the uninstall registry.
      2. Tries the recorded QuietUninstallString / UninstallString.
      3. Tries msiexec /x {ProductCode} /qn /norestart.
      4. If both fail with 1714 or 1605, removes the orphaned registration
         key so the new MSI installs clean instead of trying to upgrade
         something it cannot remove.

    IT DOES NOT install an agent. After this runs, the BDR's next discovery or
    a re-run of the v13 upgrade script pushes a current agent automatically.

    BACKUP DATA IS NOT TOUCHED. Backups live on the repository, not on the
    endpoint. Removing the agent does not remove restore points, and the
    machine stays in its protection group.

.NOTES
    Author  : Z. Boogher
    Version : 1.1
              - in REPAIR mode the script now reboots the endpoint when
                a pending reboot is what blocks the uninstall, rather
                than reporting and waiting. That is the commonest cause
                of MSI 1714: Windows Installer will not uninstall
                anything while a reboot is outstanding, and on <WORKSTATION01>
                the agent registration was intact - the machine simply
                owed a restart. It also reboots when the uninstall
                itself leaves one pending.
                REPORT mode never reboots. allowReboot=0 disables it.

    TARGET: protected ENDPOINTS whose agent will not upgrade. Not BDRs.
    Run As: SYSTEM.

    RMM variables (String, optional):
      mode         report | repair  (default report)
      allowReboot  0/1              (default 1) - in REPAIR mode only,
                   reboot the endpoint when a pending reboot is what is
                   blocking the uninstall. Never reboots in report mode.
      orgName      folder and mutex prefix (default ORG); logs land in
                   %ProgramData%\<ORG>\Logs\VeeamAgentRepair

    Exit codes - READ THE LOG, NOT THE BADGE:
      0  nothing to repair, or the repair succeeded
      2  report mode found something to repair, or a reboot is pending
      1  the repair failed and the endpoint needs hands
    NinjaOne renders exit 2 as FAILURE. A report run that finds work shows red
    by design.
#>

#Requires -Version 5.1

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType] 'Tls12'

# NinjaOne runs 32-bit; the uninstall registry and msiexec need the 64-bit view.
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -and -not [Environment]::Is64BitProcess) {
    $sysNative = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysNative) {
        & $sysNative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$OrgName   = if ($env:orgName) { ([string]$env:orgName).Trim() } else { 'ORG' }
$LogFolder = Join-Path $env:ProgramData "$OrgName\Logs\VeeamAgentRepair"
$MutexName = "Global\$OrgName-VeeamAgentRepair"
$Retention = 10
$Mode = if ($env:mode) { ([string]$env:mode).Trim().ToLower() } else { 'report' }
if ($Mode -notin @('report','repair')) { $Mode = 'report' }
# A pending reboot is the commonest cause of MSI 1714 - Windows Installer
# refuses to uninstall anything while one is outstanding. In repair mode the
# script clears it rather than reporting and waiting for a person. Set
# allowReboot=0 to report instead.
$AllowReboot = -not ($env:allowReboot -eq '0')
$RebootDelaySeconds = 60

$UninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Write-Log {
    # Write-Host deliberately - Write-Output would put log text on the pipeline
    # and corrupt any function whose return value is assigned.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The RMM captures the host stream as the job activity log. Write-Output would put log text on the pipeline and corrupt any function whose return value is assigned.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Write-Log is the script-library logging shim. The target host is Windows PowerShell 5.1, which has no built-in Write-Log; the analyzer flags it against a newer runtime list.')]
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

function Get-VeeamAgentEntries {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns every matching uninstall entry; the plural is the contract.')]
    param()
    $out = @()
    foreach ($e in @(Get-ItemProperty -Path $UninstallPaths -ErrorAction SilentlyContinue)) {
        if (-not $e.DisplayName) { continue }
        if ($e.DisplayName -notmatch '(?i)^Veeam Agent for Microsoft Windows|^Veeam Agent for Windows') { continue }
        $out += [pscustomobject]@{
            DisplayName     = [string]$e.DisplayName
            DisplayVersion  = [string]$e.DisplayVersion
            ProductCode     = [string]$e.PSChildName
            UninstallString = [string]$e.UninstallString
            QuietUninstall  = [string]$e.QuietUninstallString
            KeyPath         = [string]$e.PSPath
        }
    }
    return @($out)
}

function Test-RebootPending {
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $k) { return $true }
    }
    try {
        $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($v -and $v.PendingFileRenameOperations) { return $true }
    } catch { Write-Verbose $_.Exception.Message }
    return $false
}

# --- Single instance. An abandoned mutex from a crashed run is acquired, not fatal.
$mutex     = New-Object System.Threading.Mutex($false, $MutexName)
$haveMutex = $false
try   { $haveMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) { Write-Log 'HALTED: another instance is already running.' 'WARN'; exit 2 }

if (-not (Test-Path -LiteralPath $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
Get-ChildItem -LiteralPath $LogFolder -Filter 'agent-repair_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $Retention |
    Remove-Item -Force -ErrorAction SilentlyContinue
$transcript = Join-Path $LogFolder ("agent-repair_{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $transcript -Force | Out-Null

$exitCode = 0
try {
    Write-Log "=== Veeam Agent Registration Repair v1.0 - $env:COMPUTERNAME - mode=$Mode ==="

    $svc = Get-Service -Name 'VeeamEndpointBackupSvc' -ErrorAction SilentlyContinue
    Write-Log ("Veeam Agent service: {0}" -f $(if ($svc) { "$($svc.Status), $($svc.StartType)" } else { '<not installed>' }))

    $entries = Get-VeeamAgentEntries
    if ($entries.Count -eq 0) {
        Write-Log 'No Veeam Agent found in the uninstall registry. Nothing to repair - the backup server can install a fresh agent.'
        exit 0
    }
    foreach ($e in $entries) {
        Write-Log ("Found: {0} {1}  product {2}" -f $e.DisplayName, $e.DisplayVersion, $e.ProductCode)
    }

    if (Test-RebootPending) {
        # THIS IS USUALLY THE WHOLE PROBLEM.
        # Windows Installer refuses to uninstall anything while a reboot is
        # outstanding, which is what produces "Error 1714. The older version of
        # Veeam Agent cannot be removed" on the backup server's push. On
        # <WORKSTATION01> the agent registration was intact - the machine simply owed
        # a restart. Clearing it needs no registry surgery at all.
        if ($Mode -eq 'report') {
            Write-Log 'A reboot is pending on this machine, and that alone will block the uninstall. Windows Installer refuses while one is outstanding. Run mode=repair to clear it.' 'WARN'
            $exitCode = 2
            exit $exitCode
        }
        if (-not $AllowReboot) {
            Write-Log 'A reboot is pending and allowReboot=0. Nothing can be uninstalled until it completes - reboot this machine, then re-run.' 'WARN'
            $exitCode = 2
            exit $exitCode
        }
        Write-Log "A reboot is pending, and that is what is blocking the agent uninstall. REBOOTING THIS MACHINE in $RebootDelaySeconds seconds." 'WARN'
        Write-Log 'No Veeam registration is being changed - the pending reboot is the only blocker found. After it completes, the backup server can push a current agent on its next discovery.' 'WARN'
        Write-Log 'NOTE: this is a protected endpoint, not a server room device. Anyone working on it will be interrupted.' 'WARN'
        try {
            & shutdown.exe /r /t $RebootDelaySeconds /c "Clearing a pending reboot so the Veeam Agent can be upgraded" /d p:4:1 | Out-Null
            Write-Log 'Reboot scheduled. Re-run this script, or the v13 upgrade script on its BDR, once the machine is back.'
        } catch {
            Write-Log "Could not schedule the reboot: $($_.Exception.Message). Reboot this machine by hand." 'ERROR'
            $exitCode = 1
            exit $exitCode
        }
        $exitCode = 2
        exit $exitCode
    }

    if ($Mode -eq 'report') {
        Write-Log ("REPORT ONLY - {0} Veeam Agent registration(s) present. Set mode=repair to remove them so the backup server can push a current agent." -f $entries.Count) 'WARN'
        $exitCode = 2
        exit $exitCode
    }

    # ---- repair -------------------------------------------------------------
    $fixed = @(); $failed = @()
    foreach ($e in $entries) {
        Write-Log ("Removing {0} {1} ..." -f $e.DisplayName, $e.DisplayVersion) 'WARN'
        $gone = $false
        $lastCode = $null

        # 1. the vendor's own quiet uninstall, if it recorded one
        if (-not $gone -and $e.QuietUninstall) {
            try {
                Write-Log "  trying QuietUninstallString"
                $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $e.QuietUninstall -Wait -PassThru -WindowStyle Hidden
                $lastCode = $p.ExitCode
                Write-Log "  exit $lastCode"
                if ($lastCode -eq 0 -or $lastCode -eq 3010) { $gone = $true }
            } catch { Write-Log "  failed: $($_.Exception.Message)" 'WARN' }
        }

        # 2. msiexec by product code
        if (-not $gone -and $e.ProductCode -match '^\{[0-9A-Fa-f-]{36}\}$') {
            try {
                Write-Log "  trying msiexec /x $($e.ProductCode)"
                $p = Start-Process -FilePath 'msiexec.exe' `
                     -ArgumentList '/x', $e.ProductCode, '/qn', '/norestart', 'REBOOT=ReallySuppress' `
                     -Wait -PassThru -WindowStyle Hidden
                $lastCode = $p.ExitCode
                Write-Log "  exit $lastCode"
                if ($lastCode -eq 0 -or $lastCode -eq 3010) { $gone = $true }
            } catch { Write-Log "  failed: $($_.Exception.Message)" 'WARN' }
        }

        # 3. the registration itself is the problem - remove it
        # 1605 = this action is only valid for installed products; 1614 = product
        # is not installed; 1612 = the installation source is unavailable. All
        # three mean Windows Installer cannot uninstall what the registry claims
        # is there, which is exactly the state that produces Error 1714 on the
        # BDR's upgrade attempt.
        if (-not $gone) {
            if ($lastCode -in @(1605, 1612, 1614) -or $null -eq $lastCode -or $lastCode -eq 1603) {
                try {
                    Write-Log ("  uninstall not possible (exit {0}) - the registration is orphaned. Removing the registry key so a fresh MSI can install cleanly." -f $lastCode) 'WARN'
                    Remove-Item -LiteralPath $e.KeyPath -Recurse -Force -ErrorAction Stop
                    $gone = $true
                    Write-Log "  registration removed."
                } catch { Write-Log "  could not remove the registration: $($_.Exception.Message)" 'ERROR' }
            }
        }

        if ($gone) { $fixed += "$($e.DisplayName) $($e.DisplayVersion)" }
        else { $failed += "$($e.DisplayName) $($e.DisplayVersion) (last exit $lastCode)" }
    }

    # ---- confirm ------------------------------------------------------------
    $after = Get-VeeamAgentEntries
    Write-Log '--- Result ---'
    Write-Log ("Cleared : {0}{1}" -f $fixed.Count, $(if ($fixed.Count) { ' - ' + ($fixed -join '; ') } else { '' }))
    if ($failed.Count -gt 0) { Write-Log ("FAILED  : {0} - {1}" -f $failed.Count, ($failed -join '; ')) 'ERROR' }
    Write-Log ("Veeam Agent entries remaining: {0}" -f $after.Count)

    if ($after.Count -eq 0) {
        Write-Log 'This endpoint is ready. The backup server will install a current agent at its next discovery, or on the next run of the v13 upgrade script.' 'WARN'
        if (Test-RebootPending) {
            if ($AllowReboot) {
                Write-Log "The uninstall left a reboot pending. REBOOTING in $RebootDelaySeconds seconds so the backup server can push a clean agent." 'WARN'
                try { & shutdown.exe /r /t $RebootDelaySeconds /c "Completing Veeam Agent removal" /d p:4:1 | Out-Null } catch { Write-Log "Could not schedule the reboot: $($_.Exception.Message)" 'ERROR' }
            } else {
                Write-Log 'A reboot is now pending from the uninstall - complete it before the next push.' 'WARN'
            }
            $exitCode = 2
        }
        else { $exitCode = 0 }
    } else {
        Write-Log 'Veeam Agent registrations are still present. This endpoint needs hands - try the Microsoft Program Install and Uninstall troubleshooter.' 'ERROR'
        $exitCode = 1
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    $exitCode = 1
}
finally {
    try { Stop-Transcript | Out-Null } catch { Write-Verbose $_.Exception.Message }
    if ($haveMutex) { try { $mutex.ReleaseMutex() } catch { Write-Verbose $_.Exception.Message } }
}

exit $exitCode