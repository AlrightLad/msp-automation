<#
.SYNOPSIS
    Convergent Veeam B&R upgrade to 13.1.0.411 with dual-runtime Veeam
    PowerShell, disk reclamation, agent-blocker remediation,
    install-window watchdog, component upgrade, and post-reboot
    validation.

.DESCRIPTION
    NEW IN v4.5 - ANSWER FILE SCHEMA VERSION

      Veeam version-stamps the unattended answer file. The 13.1.0.411
      ISO ships every sample under Setup\Silent\AnswerFiles at
      version="1.1"; the 12.3.2 ISO uses "1.0". A mismatch is rejected
      before setup does any work:

        event id="102" "Invalid answer file provided."
        "Unable to use an answer file generated from a different
         product version."

      That is exactly what killed all seven 13.1 attempts in the
      2026-09-22 wave - 1603 within 23-26 seconds, no setup logs
      written, nothing changed on the box. Since a single run can cross
      both ISOs on the two-hop path, the schema now follows the track
      rather than being fixed, and the value written is logged.

      CHECK THIS FIRST ON ANY FUTURE VEEAM MAJOR VERSION. Mount the
      ISO and read the version attribute from
      Setup\Silent\AnswerFiles\VBR\VbrAnswerFile_upgrade.xml before
      running anything at scale.

    FROM v4.4 - RETARGETED TO VEEAM 13.1

      TARGET IS NOW 13.1.0.411 (v13.1, released 2026-07-30), was
      13.0.2.29. The upgrade FLOOR IS UNCHANGED at 12.3.1.1139: Veeam
      KB4763 and the v13.1 release notes both state that 12.3.1 (build
      12.3.1.1139) or later upgrades straight to 13.1, and earlier 12.x
      builds need a hop to 12.3.1+ first. The INTERMEDIATE/DIRECT track
      logic and the 12.3.2 intermediate ISO are therefore unchanged.

      EXPECT A LOT OF 3010 RESULTS ON THE FIRST WAVE. 13.1 requires
      Microsoft .NET 10 as a prerequisite. Setup installs it, returns
      3010 (ERROR_SUCCESS_REBOOT_REQUIRED) with the product build
      unchanged, and stops. v4.3 added correct handling for exactly this:
      the script reboots and the NEXT run performs the upgrade. Budget
      THREE cycles per device rather than two - prerequisite + reboot,
      upgrade + reboot, validate.

      DEVICES ALREADY ON 13.0.2.29 ARE NO LONGER AT TARGET. They take
      the DIRECT track and hop once to 13.1.0.411.

      DO NOT USE THE 13.1.1.18 ISO AS THE TARGET. Veeam R&D forum
      reports (2026-08-14) that the full ISO named
      VeeamBackup&Replication_13.1.1.18_YYYYMMDD.iso installs BASE
      13.1.0.411 and requires a separate patch ISO/EXE from the updates
      folder to reach 13.1.1.18 - the same base-vs-label trap as the
      12.3.2.4465 ISO, which installs base 12.3.2.3617. Targeting
      13.1.0.411 avoids it entirely. If 13.1.1.18 is wanted later it
      needs its own patch pass, not a target change.

      NOTE: the 13.0 branch continued after 13.1 shipped - 13.0.3.63 was
      released 2026-08-25, AFTER 13.1.1.18. Anyone comparing build
      numbers should not assume 13.0.x is always older.

    FROM v4.3 - both from the v4.2 fleet wave:

      SYSTEM-DRIVE FLOOR LOWERED 35 -> 31 GB. Setup needs ~29.3 GB on
      C:. A 35 GB gate halted <SERVER01> (31.8), <SERVER02> (33.8),
      <SERVER03> (34.0) and <SERVER04> (29.8) - four boxes that already had
      enough room. 31 keeps headroom without blocking them. Genuinely
      short boxes (<SERVER05> 27.1, <SERVER06> 24.0, <SERVER07> 21.5) still halt.

      COMPONENT-LOG FILTER WIDENED. The old filter
      '^(VeeamPlugin|VeeamExplorer|Veeam[A-Za-z]+)\.log$' demanded
      letters only before ".log", so it never matched real filenames
      such as Veeam.Setup.Extensions.Host_2026-08-11-41-17.log which
      contain dots, digits and underscores. That is why <SERVER08>
      logged a PARTIAL SUCCESS and then "No individual component log
      identified the failure" - the scanner was looking for a filename
      shape that does not exist.

    FROM v4.2 - all four from the 2026-08-11 fleet wave:

      3010 IS NOT A FAILURE. <SERVER09> returned exit 3010 with the
      build unchanged, and the installer's own result document said why:
        event id="012" "Reboot is required to finalize prerequisites
        installation." / Microsoft Visual C++ 2017-2026 Redistributable
      3010 is ERROR_SUCCESS_REBOOT_REQUIRED. Setup installed a
      prerequisite and stopped deliberately BEFORE the product install.
      v4.1 threw FATAL. The correct action is reboot and re-run - the hop
      completes on the next pass. (The result XML went to stderr, not to
      the setup temp folder, which is why "No UnattendedInstallation
      Result_*.xml found" appeared alongside it.)

      SYSTEM-DRIVE SPACE. Veeam setup needs ~29.3 GB on C: for MSI
      extraction and component installs NO MATTER where the ISO is
      staged (event id=105 on <SERVER05> and <SERVER07>). v4.1 moved the
      FreeSpace gate to the staging volume and lost the C: check
      entirely. Both gates now exist.

      ENDPOINT REBOOT BLOCKS AGENT UPGRADES. An online agent with
      RebootRequired=True on the endpoint cannot finish upgrading until
      that workstation reboots - the in-script upgrade simply timed out
      after 600 s (<SERVER10>, <SERVER11>, <SERVER12>). It now halts
      immediately, naming the machine, instead of burning the wait.

      VALIDATION THRESHOLDS. A box that misses one hourly backup cycle
      during its upgrade reboot tripped the restore-point checks
      (<SERVER13>: newest point 5 h back; <SERVER14>: 8 points fewer) and
      was permanently held. Tolerance is now 26 h backwards and a 10%
      count drop, which still catches the real cases: <SERVER15>
      (newest point 4.5 MONTHS backwards) and <SERVER16> (-85 of 265 points).

    FROM v4.1:
      Veeam log-tree pruning (C:\ProgramData\Veeam\Backup was 58.47 GB /
      12,522 files on <SERVER17>, oldest 2024-04-11 - the real cause of the
      FreeSpace halts, hidden because ProgramData is hidden); component
      upgrade via Update-VBRServerComponent; 9392 listener checked with
      netstat because Get-NetTCPConnection -State Listen returns nothing
      intermittently on a busy box (<SERVER17>: netstat showed LISTENING while
      the cmdlet came back empty amid ~40 TIME_WAIT entries).

      VSPC IS NOT AUTOMATABLE - the v13 module exposes no
      ManagementAgent/ServiceProvider/VSPC/CloudConnect cmdlets, and
      Veeam ServiceAgent is 9.3.0.35057 identically on 12.x and 13.x, so
      it is not an agent version either. Console action, logged as such.

    FROM v4.0:
      Staging on the largest fixed volume (eight fleet boxes have
      109-117 GB C: beside a multi-TB D:); installer task launch
      verified before trusting a result (<SERVER18>: stale LAPS, task never
      ran, LastTaskResult 0 read as success - Security 4625 substatus
      0xC000006A); credential pre-validated before the download;
      StopPending detected at preflight and cleared by forced reboot;
      agent-removal splat fixed (PowerShell splats from a VARIABLE only);
      log output capped by characters as well as lines; all reboots
      forced.

    Port 443: v13 installs its own web service which legitimately binds
    443 - only a NON-Veeam listener is a conflict. 17 halts became 0.

    CONFIGURATION BACKUP IS NOT A GATE (Z. Boogher). Much of the fleet
    has a broken configuration-backup job and halting those upgrades
    protected a rollback point the devices did not have. Not repairable
    by cmdlet - all four *ConfigurationBackup* cmdlets enumerated on
    both 12.2 and 13.0, neither exposes a settings-level setter, and the
    dangling GUID is stored binary. Separate workstream.

    DUAL RUNTIME - Veeam PowerShell v13 requires PowerShell 7 (.NET
    Core); NinjaOne runs 5.1. The v12 module is .NET Framework and fails
    under pwsh with "The type initializer for
    'Veeam.Backup.Common.SSslOptions' threw an exception". Runtime is
    chosen PER CALL from the installed build.

    THE INSTALL-WINDOW WATCHDOG - the installer restarts VeeamBackupSvc
    to analyse the config DB, and each service start spawns maintenance
    jobs that prevent the service stopping. The installer allows 5
    minutes then fails event id=113 and rolls back. Pre-stopping cannot
    fix it - the blocking jobs appear AFTER the restart.

    FORCE-KILLING THE SERVICE IS NOT USED TO INSTALL - taskkill wedged this
    platform in the August pilot, when SCM auto-restart brought the service
    back under the installer. Graceful stop only; forced reboot and retry on
    failure. The one exception (4.52) is RECOVERY: a VeeamBackupSvc already
    stuck in StopPending with no workers and no installer running is ended
    and started fresh, so the jobs can be restored.

    NOTE FOR TECHS: the v13 console must be launched AS ADMINISTRATOR or
    it fails with "Access to the registry key ...\Plugins is denied" -
    that key grants Administrators, and a non-elevated process carries
    that as a deny-only SID under UAC.

.NOTES
    Author  : Z. Boogher
    Version : 4.53 - THE PATCH-STEP FILE LOCK, AND A REAL PS7 REPAIR
              - the patch step failed 1603 with no installer event on
                <SERVER19>, <SERVER20>, <SERVER21>, <SERVER22>, <SERVER23> and <SERVER24>. Cause found on
                <SERVER19>: the Service Provider Console agent
                (VeeamManagementAgentSvc / Veeam.AC.Agent.exe) launches
                pwsh with the Veeam module ~every 10 s to poll Backup &
                Replication, and the patch track does not pre-stop
                services, so a poll is mid-flight when setup checks its
                files - "unable to update the following files, because
                they are locked by an external process". Proven fix: with
                that agent stopped, <SERVER19> patched to 13.1.1.18. The patch
                track now pauses VeeamManagementAgentSvc (set Manual so the
                exit guard does not restart it mid-patch, kill any live
                poll) and restores it after - inline and in the finally.
                SPC loses sight of the box only for the patch window.
              - Repair-Pwsh7 now has a second route. The cached-package
                msiexec /fa failed 1603 on <SERVER25> because Windows stores big
                installers stripped, so there was nothing to re-lay. It now
                falls back to a fresh, version-matched, Authenticode-
                verified MSI from GitHub (REINSTALL=ALL REINSTALLMODE=amus)
                - exactly what fixed <SERVER25> by hand. Refuses to run anything
                not validly signed by Microsoft.
              - (4.52) A WEDGED SERVICE NO LONGER LEAVES A SITE DARK
              - <SERVER26> went most of a day with all six jobs off.
                Its VeeamBackupSvc sat in StopPending with no workers,
                looping "[CAgentCloseExecuter] ... Safe handle has been
                closed" 2,058 times in 3,000 log lines. While it sat there
                the Veeam API was unreachable, so the run's job restore
                had nothing to talk to - and the exit guard only restarted
                services reading Stopped, which StopPending is not.
              - Reset-WedgedBackupService ends a VeeamBackupSvc stuck in
                StopPending, starts it fresh and confirms it, so the jobs
                can be restored - exactly what worked by hand on 4783. It
                runs at the start of a run, on the stop-failure path and
                in the exit guard. RECOVERY ONLY: never while the installer
                task or Veeam.Silent.Install is running, never while a
                worker is still alive, and never to push an install
                through - installs still need a graceful stop.
              - (4.51) THE FIXES DONE BY HAND, DONE BY THE SCRIPT
              - full-hop C: floor 30 -> 33 GB. Setup asked for exactly
                32.27 GB on <SERVER03> and <SERVER20> (event 105), so both
                passed preflight and failed at the install with jobs
                already paused. The patch track keeps 30 GB.
              - the deep disk clean adds the four steps proven by hand on
                <SERVER03>, <SERVER06> and <SERVER20>: Delivery Optimization cache, Veeam
                logs older than 7 days (never a repository path), old
                Veeam setup logs, and hibernation off.
              - PendingReboot now counts pending file renames - what
                installers actually check. <SERVER27>, <SERVER28> and <SERVER29> passed
                the old gate, then setup refused "reboot required". Acted
                on once; if renames survive this script's reboot they are
                logged as sticky for a person, never rebooted for forever.
              - setup refusing with event 013/012 "reboot required" now
                gets one reboot (through the job guard) so the next run
                upgrades. Once only, same rule.
              - a VeeamBackupSvc already stuck in StopPending before the
                run touches anything gets one reboot - no jobs are paused
                at that point (<SERVER29>). Once only, same rule.
              - PowerShell 7 that exists but cannot start is repaired from
                its own cached installer (msiexec /fa), then Veeam is
                queried (<SERVER25>, System.Private.CoreLib.dll).
              - a failed PATCH writes PATCHDIAG: lines - reboot flags,
                pending renames, C: free, and the error lines from any
                log the patch left, including the install account's TEMP.
                <SERVER19>, <SERVER20>, <SERVER21>, <SERVER22>, <SERVER23> and <SERVER24> failed the patch
                with no installer event; the next run says why.
              - (4.50) NO REBOOT UNTIL THE JOBS ARE CONFIRMED BACK
              - every forced reboot now goes through one fail-closed guard.
                All six reboot paths call Invoke-ForcedReboot, which tried a
                job restore and rebooted whatever the result. The v4.48 guard
                covered one of the six and treated "could not read the jobs"
                as "nothing is disabled". <SERVER30>, 2026-09-29: Get-VBRJob
                refused on 127.0.0.1:9396, both restores failed, the log read
                "JOBS MAY STILL BE PAUSED" - and it force-rebooted at 17:36:17,
                killing the exit guard mid-way through restarting services.
                Now, if this run paused jobs, the guard brings the services
                up, waits for Veeam to genuinely answer a job query, restores,
                and VERIFIES. If the jobs cannot be confirmed enabled - or
                their state cannot be read - the reboot is skipped, the run
                exits 2, and the exit guard finishes the restore.
              - the exit guard's "API responding" probe never called Veeam,
                so it could report the API up while job queries were refused.
                It now runs a real Get-VBRJob.
              - the write to the veeamUpgradeState custom field is removed;
                that field was never created, and every run logged an error
                trying to write it.
              - (4.49) AN AGENT IS JUDGED BY VEEAM, NOT BY ITS NEIGHBOURS
              - the agent stage decided whether an endpoint was current by
                comparing it to the NEWEST AGENT ALREADY AT THAT SITE. A
                site with one endpoint compared the agent to itself and
                called it current; a site whose agents were all old called
                every one current. Nothing was upgraded, and single-server
                agent jobs failed hourly with "Backup agent server01
                requires upgrade" / "Server server01 has an outdated Data
                Mover service version" (servers01, 0 of 1 hosts processed,
                2026-09-29). The stage now uses Veeam's own AgentStatus
                (UpgradeAvailable) wherever the property exists, and only
                falls back to the version comparison on builds without it.
              - if the update path returns nothing or throws, the agent is
                upgraded through Install-VBRDiscoveredComputerAgent - the
                deploy path proven on <SERVER21> to run a real
                "Operation UpgradeAgent" MSI. Its session Result is read,
                because it returns Failed rather than throwing; a failure
                names the endpoint and points at Veeam Agent Registration
                Repair, since a pending reboot has been the cause every time.
              - the old fallback that applied the first update object found
                for ANY computer to this one is removed.
              - (4.48) KILL THE WEDGED WORKER, NEVER REBOOT DARK
              - the service-stop stall is finally fixed at the root. When
                Stop-Service -Force did not finish in the window, the
                code that would kill the holding worker was DISABLED
                (if ($false){}), so the stop sat idle for the full
                budget and failed. At the STOP stage a
                Veeam.Backup.Manager.exe worker does NOT respawn - the
                service is trying to exit - so killing that specific PID
                is what clears it, exactly as it did by hand on
                <SERVER31> and every stuck box since. That kill now
                runs after the grace period instead of doing nothing.
              - NEVER REBOOT WITH JOBS DISABLED. The stop-failure path
                restarted services but left job schedules paused, then
                rebooted - leaving the site backing up nothing.
                <SERVER32> did exactly this: 4 jobs disabled,
                force-rebooted. The script now restores jobs before any
                reboot on that path, and if they will not come back it
                HALTS and names them rather than rebooting into a dark
                site.
              - (4.47) THE DEVICE WRITES ITS OWN STATE
              - every fleet number this project produced was wrong at
                some point, and never because the fleet was wrong:
                  * NinjaOne truncates activity output at 10,003 chars,
                    and successful runs produce the longest logs, so
                    completions were invisible.
                  * v2/queries/software lags. CONFIRMED 41 hours on
                    <SERVER33> - same installDate, version field
                    moved 13.0.2.29 -> 13.1.1.18 with no intervening
                    install. An "up to 2 hours" assumption was carried
                    into three reports before it was checked.
                  * v2/activities caps at 400 pages, roughly 12 hours,
                    so "never received the script" often meant "ran
                    outside the window that could be seen".
                All three are properties of the REPORTING PATH. The
                device knows its version and its outcome the moment the
                run ends.
                The script now writes that to the custom field
                veeamUpgradeState via Ninja-Property-Set, from the
                device, at every exit including FATAL:
                  v1|<utc>|<script ver>|<arp>|<file ver>|<state>|<exit>|<detail>
                One v2/queries/custom-fields call reads the true state
                of all 267 with no lag, no truncation and no paging.
                CREATE THE FIELD FIRST: device custom field,
                type Text, scriptable read/write, name veeamUpgradeState.
              - (4.46) SAY WHY THE AGENT PUSH FAILED
              - when an agent upgrade does not land, the script now
                reads Veeam's own per-agent deployment log at
                ProgramData\Veeam\Backup\Rescan\Rescan_of_<name>\
                Task.<name>-deploy.log and reports the MSI result and
                error. That log already held the answer on
                <SERVER21>: "Package installation result: is success:
                False (code: 1603)" and "Error 1714. The older version
                of Veeam Agent for Microsoft Windows cannot be removed."
                The script had been saying only "agent upgrade did not
                complete", which cost an hour of log archaeology for
                something sitting on disk.
              - MSI 1714 is called out by name: the BDR push is working,
                the ENDPOINT's Windows Installer registration is broken,
                and it needs the endpoint repair script rather than
                another attempt from here.
              - this also corrects a wrong conclusion recorded earlier
                in this file's history: Install-VBRDiscoveredComputer-
                Agent is NOT rescan-only. It dispatches a real
                "Operation UpgradeAgent" deployment and runs
                Veeam_B&R_Endpoint_x64.msi on the endpoint. Earlier
                tests looked like no-ops because those agents were
                already current.
              - (4.45) THIS SCRIPT NEVER REMOVES AN AGENT REGISTRATION
              - the proactive sweep's removal path is gone. It was the
                last place the script could delete a discovered-computer
                registration and it is now report-only, like the
                installer-named path before it. An offline registration
                is not evidence a machine is dead - it is evidence the
                agent has not checked in. <HOSTNAME>.<CLIENT>.local on
                <SERVER34> looked exactly like a removal candidate
                and was ONLINE with 400 restore points in a live job.
                Stale registrations are named for a person to decide.
              - the blocked-agent message now says plainly that VEEAM
                SETUP is what refuses to proceed, not this script.
                Setup will not install while an outdated agent is
                registered (report severity=error, "Outdated Veeam
                Agents"). The script upgrades every blocker it can
                reach; one it cannot reach stops the hop because setup
                stops it, and the fix is to bring that machine online.
              - (4.44) A FAILURE DUMP MUST NOT COST THE REST OF THE RUN
              - v4.42 skipped the setup-log dump on exit 0/3010 only, so
                a 1603 still printed everything and blew past NinjaOne's
                10,003-character cap. That hid the agent remediation and
                the retry that follow a failed install - six devices on
                the 2026-09-25 wave went dark exactly that way, and
                whether the script had fixed its own blocker became
                unanswerable from the feed.
                A failure now prints the setup report's error-severity
                entries and the objects they name, which is what
                actually explains it, and nothing else. The full logs
                stay on disk.
              - (4.43) RESULT build field
              - the RESULT line reported
                "build=System.Collections.Hashtable".
                Get-InstalledVbrBuild returns an object carrying .Build,
                not a version, so .ToString() rendered the wrapper. exit
                and arp were always correct so the completion test was
                unaffected, but the build field was useless.
              - (4.42) A LOG SHOULD SAY WHAT HAPPENED, NOT WHAT DIDN'T
              - setup-log and installer-XML dumps now print ONLY when
                the installer returned something other than 0 or 3010.
                They are 4-7 thousand characters, they are produced by
                every SUCCESSFUL install, and nobody reads them on a
                clean run - which is precisely how a successful run
                ended up truncated while a failed one fitted inside the
                cap. On a failure they still print in full, because
                then they are the only thing that explains it.
              - the seventeen preflight gates no longer take a line
                each. Failures keep their full detail, the two disk
                gates keep their values, and the rest collapse to one
                "PASS (15): name, name, ..." line. That is ~1,300
                characters returned to the budget.
                Together these take a successful run from roughly
                10,000 characters to around 3,000.
              - (4.41) THE OUTCOME MUST SURVIVE THE FEED CAP
              - NinjaOne truncates activity output at 10,003
                characters. The setup-log and installer-XML dumps are
                the longest thing a run produces, and only SUCCESSFUL
                installs produce them - so "Post-upgrade build:" and
                "HOP COMPLETE", written at the very end, were cut off on
                exactly the devices that hopped. <SERVER35> patched
                cleanly to 13.1.1.18 at 00:26:43Z and three consecutive
                fleet polls reported ZERO hops: its record ended
                mid-word at 10,003 characters with 33 seconds of the run
                still to go. Every hop count reported for v4.37 and
                v4.38 was a lower bound, biased in the worst direction.
                A single compact RESULT: line is now emitted straight
                after the installer exit code and before any dump:
                  RESULT: track=X exit=N from=A to=B build=C arp=D attempt=N
                Match on that for completion, not on the tail markers.
              - (4.40) UPGRADE THE BLOCKER, NEVER REMOVE IT
              - VbrDatabaseIssuesSetupReport.xml says "upgrade OR
                remove" an offending agent. v4.39 took the second
                option and that was wrong. On <SERVER34> the named
                machine was <HOSTNAME>.<CLIENT>.local - ONLINE, connected 20
                minutes earlier, 400 restore points in the Servers01
                job. Removing its registration would have dropped a
                live production server out of its backup job.
                "Not Online" does not mean decommissioned either; it
                can simply mean the agent has not checked in. So an
                installer-named machine is now UPGRADED where possible
                and HALTS, named, where not. It is never removed. A
                halted upgrade costs a run; a removed registration
                costs a client their backups. The halt message reports
                how many restore points that machine has, so anyone
                choosing to remove one does it knowing the cost.
              - the proactive staleness sweep is unchanged: it still
                clears registrations that are genuinely dormant beyond
                staleAgentDays with no restore points.
              - (4.38) RELEASE THE DEVICES THAT ARE NOT ACTUALLY BROKEN
              - a validation failure whose ONLY issue is a
                restore-point COUNT DROP no longer holds the device.
                Every job, repository and backup object still exists and
                still runs; the count fell because retention rolled a
                chain or a job was renamed. 24 devices were held this
                way and none of them could reach the current patch -
                and a BDR left behind is a BDR whose workstations go
                unprotected. A MISSING job, repository or backup object
                still holds ALWAYS: that is real, and it is what caught
                <SERVER36> losing all three offsite copy jobs.
                holdOnPointDrop=1 restores the old behaviour.
              - installer result XML is decoded as UTF-16 when it is
                UTF-16. Read as single-byte it rendered one character
                per column and swallowed the real failure reason -
                "Setup has detected critical database issues" was lost
                that way on <SERVER37> and <SERVER38>.
              - SystemDriveFreeSpace gate 31 -> 30 GB. Setup needs
                ~29.3 GB; 30 keeps headroom and releases <SERVER39>
                (30.5 GB) and <SERVER06> (30.2 GB), which missed by 500 and
                800 MB after a deep clean found nothing left to remove.
              - (4.37) A DISABLED SERVICE WAS INVISIBLE TO THE GUARD
              - the exit guard only ever examined services with
                StartType Automatic, so a core Veeam service set to
                DISABLED was never seen: never started, never reported,
                and the device silently stopped backing up. Six devices
                in the 2026-09-23 fleet had VeeamBackupSvc Disabled
                (<SERVER12>, <SERVER40>, <SERVER41>, <SERVER42>, <SERVER43>, <SERVER44>) and
                no number of re-runs would ever have touched them.
                A disabled CORE service is now set back to
                delayed-auto/auto and started, at preflight and again in
                the exit guard. Scope is limited to the services a BDR
                cannot run without - the optional platform services
                (AHV, AWS, Azure, GCP, Kasten...) are left alone, since
                a site may legitimately have turned those off.
                fixDisabledServices=0 reports without changing.
              - (4.36) CLEAR THE GATES THE SCRIPT CAN CLEAR
              - the Veeam console is now CLOSED rather than halted on.
                It is a UI process, not a site fault, and 8-9 devices
                sat on that gate in every wave. Closing it costs an
                unsaved console session and nothing else. The owning
                user is named in the log. closeConsole=0 restores the
                halt.
              - when C: is below the gate the script reclaims the
                Windows Update download cache, CBS logs older than a
                week, TEMP files older than a day, and superseded
                WinSxS components via DISM. Five devices sat on
                SystemDriveFreeSpace through every wave with 21-27 GB
                free on 109-117 GB drives and their Veeam log trees
                already pruned. NOTHING here touches Veeam data,
                repositories, the page file or hibernation - those are
                decisions for a person. deepDiskClean=0 disables it.
              - (4.35) THE COMPONENT UPGRADE RESULT WAS DISCARDED
              - v4.34 added Invoke-ComponentUpgrade to the converged
                path but threw away its return value. That function
                RETURNS a result object and logs nothing itself; the
                caller has to unpack it, as the post-validation call
                site does. So on <SERVER45> it ran - visible only as
                a silent 17-second gap between "CONVERGED" and the agent
                stage - found <HOST01> out of date, and reported nothing.
                Zero of ~70 affected sites were remediated and every one
                of those Server/VM jobs is still failing in 8-16
                seconds. Now unpacked, logged, and it states plainly
                when hosts were upgraded.
              - (4.34) CONVERGED IS NOT THE SAME AS FINISHED
              - HOST COMPONENTS ARE NOW CHECKED ON THE CONVERGED PATH.
                This is the project's biggest field failure. After the
                v4.30 patch wave, 70 sites had every Server/VM backup
                job die in 8-16 seconds - "host rescan is required",
                "Server <x> has an outdated Data Mover service version".
                The patch advances the VBR server past its managed
                Hyper-V hosts and no job can run until those hosts are
                upgraded. The component upgrade only ran after a hop or
                a validation pass, so those devices logged "CONVERGED -
                Nothing to do", exited in eight lines, and never looked.
                Remediation confirmed on <SERVER45>: <HOST01>
                IsUpToDate=False, Update-VBRServerComponent -Component
                <host> returned "Host Upgrade ... Result: Success" in 26
                seconds, IsUpToDate went True, job ran.
              - the service exit guard now tries THREE times, starting
                VeeamBackupSvc first and letting it settle before
                sweeping the rest, and on final failure writes the SCM
                event text for each service that would not start.
                <SERVER46> reported VeeamCatalogSvc "start failed"
                for six consecutive waves with no reason recorded.
              - (4.33) A PATCHED DEVICE NOW REPORTS AS CONVERGED
              - v4.31 detected already-patched devices correctly and
                skipped the patch, then printed "this device cannot
                reach 13.1.1.18 by script" at 185 of them, because the
                converged test still compared the FILE version - which
                the patch never moves. The behaviour was right and the
                message was wrong, and the message is what everyone was
                reading.
                <SERVER07> settled the detection question: patched
                2026-09-09, its VeeamBackupAndReplication13Patch log
                still on disk, product ARP row 13.1.1.18, file version
                13.1.0.411 - identical to <SERVER47> patched on
                2026-09-23. The ARP row is a sound signal; a three-day
                activity feed is simply too short to see a patch applied
                two weeks ago.
              - (4.32) LAPS ROTATES DURING THE DOWNLOAD
              - the install credential was fetched and validated at
                Stage 2.6, then used at Stage 6 - with an 18 GB ISO
                download, hash and extract in between. LAPS rotating
                inside that 20-40 minute window left the script
                registering a scheduled task with a password Windows
                then rejected, which is the "Installer task never
                entered Running ... LastTaskResult 1603" signature. It
                went from 1 device to 13 in the 2026-09-23 wave purely
                because more devices reached the installer at all.
                The credential is now re-fetched and re-validated
                immediately before each install attempt.
              - (4.31) THE PATCH DOES NOT MOVE THE FILE VERSION
              - confirmed on <SERVER47> straight after a successful
                patch (653 KB patch log, "Return value 0."):
                  Veeam Backup & Replication          13.1.1.18  MOVES
                  ...Replication Server               13.1.0.411 does not
                  ...Replication Console              13.1.0.411 does not
                  Veeam.Backup.Service.exe            13.1.0.411 does not
                v4.30 tested the file version, so SEVEN devices that
                patched perfectly were FATAL'd for "not advancing", and
                the fleet inventory reading 183 at 13.1.1.18 was
                CORRECT all along - those devices really are patched.
                Detection and post-patch verification now both use the
                bare "Veeam Backup & Replication" ARP row.
              - (4.30) THE PATCHED-DETECTION SIGNAL WAS WRONG
              - v4.19 treated "Veeam Updater Plug-in for Veeam Backup &
                Replication" reading 13.1.1.18 as proof the patch had
                been applied. It is not: that plug-in SHIPS at 13.1.1.18
                inside the 13.1.0.411 ISO. <SERVER46> sits at product
                build 13.1.0.411 with the plug-in at 13.1.1.18 and has
                never been patched; <SERVER47> is equally unpatched
                with the plug-in at 13.1.0.411.
                The test silently marked 184 devices "already patched -
                treating as converged" and is the reason
                "Post-upgrade build: 13.1.1.18" stayed at ZERO for the
                entire project. Detection now uses the product build
                alone, which the patch does move.
              - (4.29) SET LocalAccountTokenFilterPolicy, DO NOT GATE ON IT
              - that value is a prerequisite of this script's own
                install method: the installer runs as a local admin via
                a scheduled task and without it UAC hands that account a
                filtered token. It is absent by default on a workgroup
                BDR - not a site misconfiguration. Halting on it blocked
                <SERVER47> for three consecutive runs with all 16
                other gates green and the patch track correctly
                selected. The script now sets it, verifies it took, and
                says so if Group Policy overrides it.
              - (4.28) PARSE ERROR FIX
              - a variable name immediately followed by a colon inside
                a double-quoted string is parsed as a SCOPE-QUALIFIED
                VARIABLE, not as a variable followed by punctuation. It broke the whole script
                at load: "Variable reference is not valid. ':' was not
                followed by a valid variable name character." Every
                device in the 2026-09-23 22:0x wave failed at parse -
                nothing ran, nothing was changed. Braced to ${name}.
              - (4.27) MAKE THE END OF THE LOG SURVIVE
              - NinjaOne truncates activity output at ~10,003
                characters. In the 2026-09-23 fleet wave, 20 devices
                that reached the installer lost their
                "Post-upgrade build:", "HOP COMPLETE" and job-restore
                lines off the end - a successful install looked
                identical to an unknown one from the API, and job safety
                became unverifiable on exactly the devices that did the
                most work.
                Trimmed: installer STDOUT now keeps only lines matching
                error/fail/warn/exception/event id/reboot (stderr keeps
                its full budget - the result document lives there); the
                service-stop progress line drops from every 2 minutes to
                every 5; the exit guard names 6 services instead of 27;
                auxiliary stop failures collapse to one summary line.
              - (4.26) THE EXIT GUARDS WERE IN THE WRONG ORDER
              - the job guard ran BEFORE the service guard, so every
                restore was attempted against a stopped VeeamBackupSvc
                and failed. <SERVER19> and <SERVER48> logged
                "COULD NOT RE-ENABLE FROM MEMORY after 3 attempts", then
                the final sweep, and only THEN "EXIT GUARD: 27
                auto-start Veeam service(s) are stopped - starting
                them". Two sites were left with jobs disabled by an
                ordering mistake. Services now come up first.
              - and the job guard waits for the Veeam API to actually
                respond before restoring - SCM reporting Running is not
                the same as the API answering.
              - (4.25) THE SERVICE STOP WAS THE WRONG CALL
              - the script used "sc.exe stop", a fire-and-forget SCM
                control request that returns immediately and does
                nothing about dependent services. It now uses
                Stop-Service -Force, which walks the dependency tree,
                stops dependents first, and blocks until the service is
                actually down.
                PROVEN: on a device from the 110-strong stuck
                population, the script's sc.exe approach timed out at
                900 s with STARTINFRARESCAN apparently holding it, while
                a plain "Stop-Service VeeamBackupSvc -Force" on the SAME
                box reached Stopped in minutes. The rescan was never the
                blocker.
              - the 5-minute stuck-rescan bail added in v4.24 is gone.
                It would now abandon a stop that is about to succeed.
              - the watchdog no longer terminates workers during the
                stop at all. Every dispatcher-managed verb respawns on
                kill, and a proper stop clears them by itself.
              - (4.24) PAUSE SAFELY, DO NOT STOP PAUSING
              - job pausing stays ON. Without it the install waits for a
                quiet window that may never come on an hourly-backup
                site, the device loops failing runs, and the office is
                unprotected for longer than the upgrade would have
                taken.
              - THE RESTORE NO LONGER DEPENDS ON A FILE. Every incident
                in this script's history came from jobs-paused.json
                being missing, overwritten with an all-disabled baseline,
                or misread. The job names are now held in memory for the
                life of the run and every exit path restores from memory
                first, file second.
              - FINAL SWEEP at exit: if this run paused anything and any
                job is still disabled, it is re-enabled outright - no
                conditions, no 30-day rule, no state file. A site that
                was backing up when the script started is backing up
                when it finishes.
              - the self-heal asks the JOB when it last ran instead of
                matching session names. Sessions here are recorded as
                "S3 Copy Job\HyperV Backup - <SERVER-DC>", so a job named
                "Server01" never appeared under its own name and looked
                idle. An unknown last-run now counts as recent: wrongly
                re-enabling is far cheaper than leaving a site dark.
              - STARTCHECKPOINTREMOVAL removed from the kill list. It
                respawned within 20 s of every termination on <SERVER49> and
                <SERVER50>, exactly like STARTINFRARESCAN.
              - a rescan that gets stuck DURING the stop is now caught
                at 5 minutes instead of running the full 900 s budget.
              - the script waits for the Veeam API to actually answer
                before evaluating gates. <SERVER31> halted on four gates
                reporting "Failed to connect to Identity service" 38
                seconds after its services were started.
              - a gate that could not be EVALUATED no longer counts as
                FAILED.
              - (4.22) STUCK-RESCAN DETECTION. A Veeam.Backup.Manager.exe
                running STARTINFRARESCAN for more than 15 minutes means
                VeeamBackupSvc can never be stopped. On <SERVER31>
                one had been running THIRTEEN HOURS. Killing it makes
                the service dispatch a replacement within 60 s
                ("New rescan job will be started. Reason: Session ...
                was stopped."); rebooting restarts it within minutes.
                Both were tested on that device and both fail. The
                script now detects it at preflight and halts in ~30
                seconds with the cause named, instead of spending 900
                seconds on a stop that cannot succeed and then burning a
                reboot. 120 devices did exactly that in the 2026-09-23
                wave.
              - (4.21) JOB EXIT GUARD. The self-heal previously ran only at
                script start, so a device could still END a run with its
                jobs disabled - which is how <SERVER49>, <SERVER50> and
                <SERVER31> stayed dark for over a day. Restore plus self-heal
                now also run in finally, on every path including FATAL,
                ahead of the service guard. No run can finish leaving a
                site that was backing up yesterday backing up nothing
                today.
              - the self-heal marker no longer permanently blinds the
                check. If a device was healed and its jobs are disabled
                again with recent sessions, that is a NEW failure and it
                is treated as one. Only a device judged deliberately
                quiesced stays skipped.
              - (4.20) the self-heal only re-enables jobs that have RUN in the
                last 30 days. A disabled job with no session in that
                window was almost certainly switched off deliberately -
                a decommissioned client, a migration, a BDR being
                retired - and the script has no business overriding
                that. Those are named in the log and left alone, and the
                upgrade continues regardless.
              - (4.19) SELF-HEAL NOW ACTUALLY FIRES. v4.18 required a
                jobs-paused.json to exist before it would act, which was
                backwards: <SERVER49> and <SERVER31> have had every job
                disabled since v4.7 and their state file was long gone,
                so the check returned immediately and both sites stayed
                dark. The trigger is now the job state itself.
              - AND IT NO LONGER POISONS THE BASELINE. v4.18 wrote a
                jobs-paused.json recording all-disabled on those same
                two devices, so any later restore would have faithfully
                put the jobs back to disabled. A pause pass with nothing
                enabled now writes no state file at all.
              - PATCHED DETECTION USES THE UPDATER PLUG-IN. The
                13.1.1.18 patch moves neither the product file version
                nor its ARP DisplayVersion - both still read 13.1.0.411
                afterwards, which is why <SERVER04> and <SERVER07> (patched 4 and 9
                September) were re-routed into the patch on every run.
                "Veeam Updater Plug-in for Veeam Backup & Replication"
                reads 13.1.1.18 on every patched device and is absent
                from unpatched ones.
              - the setup-log sweep is trimmed to the lines that matter.
                v4.16 dumped 20-30 lines per log, ate 35-39% of
                NinjaOne's 10,003-char activity cap, and pushed
                "Post-upgrade build:" and the job-restore confirmation
                off the end of three patch logs.
              - (4.18) SELF-HEAL FOR A SITE THIS SCRIPT LEFT DARK. v4.7's job
                pause disabled jobs and failed to restore them on five
                devices; the restore path could never recover them
                because the next run rewrote jobs-paused.json with
                wasEnabled=false for everything. <SERVER49>, <SERVER50>
                and <SERVER31> have been backing up nothing since. The script
                now re-enables everything when ALL jobs on a box are
                disabled AND a jobs-paused.json exists - a site with
                zero enabled jobs is broken, never deliberate. It does
                this ONCE, records it, and never loops against a tech
                who switches something off on purpose.
              - (4.17) AGENT UPDATE STAGE. 12 of 15 sites reported after the
                2026-09-23 wave needed "components updated" by hand
                before their jobs would run. The existing check was not
                wrong - Get-VBRPhysicalHost correctly reported the HOSTS
                as current. The stale components were the AGENTS on the
                protected endpoints (<SERVER12>: four on 13.1.1.700,
                one on 13.1.0.544, two flagged RebootRequired). The
                script used Install-VBRDiscoveredComputerAgent, which is
                the DEPLOY path; the UPDATE path is
                Get-VBRDiscoveredComputerUpdate /
                Set-VBRDiscoveredComputerUpdate. That now runs after
                every successful hop, not only after a validation pass
                on some later run.
              - endpoints reporting RebootRequired are named in the log
                as needing a WORKSTATION reboot - no script can do it
                for them and their jobs may fail until it happens.
              - an already-patched device is no longer routed back to
                the patch. <SERVER04> and <SERVER07> report 13.1.0.411 by
                file version and 13.1.1.18 in ARP; either source now
                counts as patched.
              - job restore retries three times before giving up.
                <SERVER51> paused, FATAL'd on a stale LAPS
                credential, then could not re-enable because the Veeam
                session had gone - and the site was left unprotected.
              - (4.16) THE INSTALLER NOW RUNS FROM ITS OWN FOLDER. The
                scheduled task's working directory is the log folder and
                the child process inherited it, so an ISO-root Setup.exe
                resolving .\Setup\... relatively looked in the wrong
                place. <SERVER52>, <SERVER53> and <SERVER54> returned 1603
                in 23-71 s with NO setup log, NO result document and no
                service activity - rejected before doing any work. The
                full-ISO track was unaffected because
                Setup\Silent\Veeam.Silent.Install.exe receives absolute
                paths.
              - when setup writes no result document, the script now
                sweeps the setup temp folder for any log written during
                the run and says plainly when NOTHING was written, which
                is the signature of a rejected command line rather than
                a failed install.
              - (4.15) the activity log now names the REAL fleet target
                (13.1.1.18 when enablePatch=1) rather than the ISO
                ceiling 13.1.0.411. Every run opens with the target and
                the full route, each hop line says how many hops remain,
                and a converged device reports the build it is actually
                on against the target it was measured against. A device
                at 13.1.0.411 that cannot be patched now says so
                explicitly instead of claiming it is at target.
              - (4.14) THE PATCH TRACK NO LONGER PRE-STOPS VEEAM SERVICES.
                In the 2026-09-23 wave 52 devices selected the patch
                track, 48 announced /silent, and ALL 48 died at the
                900 s service stop after 16-19 minutes - Setup.exe was
                never invoked and not one produced an installer exit
                code. 13.1.x carries 32 auto-start Veeam services where
                13.0.x had 26, so the pre-stop that works on 12.x and
                13.0.2.29 does not complete there. A hotfix installer
                manages its own services (Veeam's KB says run it
                elevated and nothing more), so the pre-stop was both
                unnecessary and fatal. stopServicesForPatch=1 restores
                it.
              - (4.13) COPY-WATCH NO LONGER HOLDS AT ALL BY DEFAULT. Getting a
                BDR onto the latest build is the point of this script:
                endpoint Veeam agents are already being moved forward by
                WinGet and a BDR on an older build cannot accept them,
                so a stale build outranks an unverified copy. The watch
                is still written, retained and reported - it simply does
                not stop a device progressing or converging.
                holdForCopyWatch=1 restores the old behaviour.
              - (4.12) COPY-WATCH NO LONGER BLOCKS A FURTHER HOP. The watch
                sits in Phase 0.5, ahead of the build check, so a device
                waiting on an offsite copy could never reach a later
                stage - <SERVER55> sat at 13.1.0.411 unable to take
                the patch because a copy from 5.5 h earlier had not run
                yet. A box with a hop still available now continues, and
                the watch file is retained so the copy is still verified
                once it is on its final build. skipCopyWatch=1 bypasses
                the hold entirely.
              - (4.11) PATCH TRACK for 13.1.0.411 -> 13.1.1.18, DISABLED BY
                DEFAULT (enablePatch=0). Per KB4738 the patch applies to
                exactly 13.1.0.411 and refuses anything else with "This
                update is not compatible with installed product
                version", so it is a third rung rather than a new
                target. The patch ISO carries only Setup.exe with no
                Setup\Silent and no answer file, so it reuses the
                scheduled-task-as-local-admin mechanism with switches
                from the patchArgs variable (default '/silent
                /noreboot'). THE SWITCHES ARE UNVERIFIED - prove them on
                one device before enabling this anywhere.
              - (4.10) THE WATCHDOG WAS CAUSING THE RESPAWN IT FOUGHT.
                STARTINFRARESCAN, STARTHVCTPRESCAN and STARTDISCOVER are
                dispatcher-managed: killing one makes the service start
                a replacement, logged verbatim as "New rescan job will
                be started. Reason: Session ... was stopped." On
                <SERVER56> the watchdog killed STARTINFRARESCAN nine
                times in ten minutes and the stop still timed out. Those
                three verbs are no longer terminated.
              - the stop budget is 900 s, not 600. VeeamBackupSvc allows
                ITSELF StopAllRunningJobsTimeout = 00:10:00 to drain, so
                600 s gave up exactly when it would have succeeded.
              - the watchdog now waits 300 s before touching any worker,
                and the progress line names what is actually holding the
                stop instead of killing blind.
              - (4.9) EXIT GUARD. The script stops 26 auxiliary Veeam
                services before the install. If the stop of
                VeeamBackupSvc then timed out it returned without
                restarting them, so the box backed up nothing until
                something else rebooted it (<SERVER56>: 26 services
                down for 10 minutes). Services are now restarted on that
                path, and a guard in finally restarts any auto-start
                Veeam service left stopped however the run ended.
              - a clean-boot retry now happens ONCE. If the box has
                rebooted since and the stop still fails, it halts and
                names itself instead of rebooting every run forever -
                120 devices looped this way in the 2026-09-22 wave.
              - (4.8) JOB PAUSE FIXED. v4.7 left three sites with their
                backups disabled. Disable-VBRJob is deprecated in v13
                for computer-backup and backup-copy jobs; it still works
                but emits WARNING text, which contaminated the JSON
                stream, threw in ConvertFrom-Json, skipped the restore,
                and then logged "Nothing on this box was changed".
                Four fixes: type-specific cmdlets
                (Disable/Enable-VBRComputerBackupJob and
                -VBRBackupCopyJob) with a fallback chain; warnings
                suppressed inside every query; the JSON parser now takes
                the LAST JSON line rather than the first brace, which
                hardens every other query too; the state file is written
                BY THE QUERY BEFORE THE FIRST DISABLE, and every failure
                path in Suspend-VeeamJobs now restores.
              - schedules are also re-enabled explicitly as soon as the
                installer returns, not only at reboot or in finally.
              - (4.7) a *Pending Veeam service must now PERSIST for 180 s
                before the script calls it wedged and reboots. v4.6 and
                earlier rebooted on the first sample, which rebooted
                healthy boxes: <SERVER50> was declared wedged, then
                found with all 28 services Running, 9392 listening and
                no SCM errors at all. It also compounds - reboot, come
                back with services still starting, see StartPending,
                reboot again - and is a plausible contributor to the
                120 clean-boot retries in the 2026-09-22 wave.
              - a device already rebooted once for a wedged service,
                which has since rebooted and is STILL wedged, now stops
                and names itself instead of rebooting every run forever.
              - (4.6) job schedules are paused and running sessions drained
                immediately before the service stop, then restored.
                Replaces the useless preflight-time NoActiveSessions
                halt: 120 devices in the 2026-09-22 wave failed their
                service stop because Veeam's scheduler fired a job
                during the 20-40 minutes of download that sat between
                the gate and the install.
                Restore runs at script start, before every deliberate
                reboot, in finally, and from the on-disk state file on
                any later run.
              - (4.5) ANSWER FILE SCHEMA IS NOW PER-ISO. The v13.1 ISO ships
                its sample AnswerFiles at version="1.1"; the 12.3.2 ISO
                expects "1.0". v4.4 hardcoded 1.0, so every 13.1 attempt
                died in ~25 s with installer event id=102 "Invalid
                answer file provided. Unable to use an answer file
                generated from a different product version." 7 of 7
                attempts failed this way, nothing was changed on any of
                them. Schema now follows the track.
              - ticket reference in the banner corrected
              - (4.4) target build 13.0.2.29 -> 13.1.0.411 (Veeam v13.1,
                released 2026-07-30). The v13 upgrade FLOOR is unchanged
                at 12.3.1.1139 - Veeam KB4763 and the v13.1 release notes
                both state 12.3.1 (build 12.3.1.1139) or later upgrades
                straight to 13.1 - so the two-hop logic is untouched.
              - (4.3) SystemDriveFreeSpace floor 35 -> 31 GB (35 halted four
                boxes that already had enough room)
              - component-log filter widened: the old regex could not
                match real Veeam log filenames, which is why
                <SERVER08> reported "No individual component log
                identified the failure"
              - (4.2) 3010 with unadvanced build = prerequisite reboot, not FATAL
              - SystemDriveFreeSpace gate restored (~35 GB on C:)
              - endpoint RebootRequired halts agent upgrade immediately
              - restore-point validation tolerates one missed cycle
              - (4.1) log pruning; component upgrade; netstat listener
              - (4.0) staging volume; task-launch check; credential
                pre-validation; StopPending reboot; agent splat
              - (3.9) Port443 Veeam-aware; ARP DisplayVersion logged
              - (3.8) configuration backup removed as a gate
              - (3.6) dual-runtime Veeam PowerShell
              - (3.5) partial-success handling
              - (3.3) install-window watchdog
              - (3.2) agent remediation + event-106 retry
              - (3.1) local writable install source per ISO
              - (3.0) Write-Log uses Write-Host
    Exit    : 0 = at target, validated, offsite copy verified
              2 = expected mid-state OR validation/agent/copy FAILURE
              1 = script failure

    DEPLOYMENT: Run As = SYSTEM.

    RMM variables (all $env:, no [switch]):
      orgName                 folder and mutex prefix (default ORG);
                                   logs land in %ProgramData%\<ORG>\Logs\VeeamUpgrade
      installAdminUser        REQUIRED. Local administrator the installer
                                   task runs as (the setup engine refuses
                                   SYSTEM). Default <LOCAL_ADMIN> fails the
                                   InstallAdminAccount gate until set.
      lapsFieldName           RMM secure custom field holding that account's
                                   current password (default lapsPassword)
      downloadUrlV13, saveFileV13, sha256V13
      downloadUrlV12, saveFileV12, sha256V12
      vbrAutoUpgrade          0/1  (default 0)
      preflightOnly           0/1  (default 0 - report-only)
      staleAgentDays          int  (default 180)
      staleRestorePointDays   int  (default 60)
      veeamLogRetentionDays   int  (default 30; 0 disables log pruning)
      closeConsole            0/1  (default 1) - close an open Veeam
                                   console instead of halting on it
      deepDiskClean           0/1  (default 1) - reclaim Windows Update
                                   cache, CBS logs, %TEMP% and WinSxS
                                   when C: is below the gate
      fixDisabledServices     0/1  (default 1) - set a Disabled core
                                   Veeam service back to delayed-auto
                                   and start it
      holdOnPointDrop         0/1  (default 0) - hold a device whose
                                   ONLY validation failure is a
                                   restore-point count drop. Missing
                                   jobs, repositories or backup objects
                                   ALWAYS hold regardless.
      upgradeComponents       0/1  (default 1)
      stopServicesForPatch    0/1  (default 0) - the patch track does
                                   NOT pre-stop Veeam services. Setting
                                   this to 1 restores the pre-stop, which
                                   is what blocked every patch attempt in
                                   the 2026-09-23 wave.
      holdForCopyWatch        0/1  (default 0) - by DEFAULT an open
                                   offsite copy watch no longer holds a
                                   device at exit 2; the watch is still
                                   recorded and reported. Set to 1 to
                                   restore the old blocking behaviour.
      enablePatch             0/1  (default 0) - OFF until proven on one
                                   device. Enables the 13.1.0.411 ->
                                   13.1.1.18 patch stage.
      downloadUrlPatch        url of the patch ISO
      saveFilePatch           patch ISO filename
      sha256Patch             patch ISO SHA256
      patchArgs               silent switches for the patch Setup.exe
                                   (default '/silent /noreboot')
      pauseJobsDuringUpgrade  0/1  (default 1) - disable job schedules for
                                   the install window, then restore
      sessionWaitMinutes      int  (default 30) - how long to wait for a
                                   running job to finish before giving up
#>

#Requires -Version 5.1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
    Justification = 'Best-effort probes against a product this script stops, installs and restarts mid-run. Each silent catch treats absence as a value, and logging every miss would spend the ~10,000-character RMM activity budget the script already has to defend. 71 occurrences, the author''s pattern throughout.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
    Justification = 'Internal helpers that act on collections (jobs, services, logs, lines, event ids). Renaming them would churn a production script for no behavioural gain.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Runs unattended under an RMM where no confirmation prompt can be answered. Report-only behaviour is the preflightOnly input, not -WhatIf.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'The RMM / RMMScriptPath / ScriptURL block is the script-library template header, preserved verbatim.')]
param()

# Enable TLS1.2 and TLS1.3
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType] 'Tls12'

$RMM = 1
$ScriptURL = $env:scripturl
$RMMScriptPath = $env:PROGRAMDATA + "\NinjaRMMAgent\scripting"
$Description = $env:description
$DownloadURL=$env:downloadurl
$SaveFile=$env:savefile

# --- 64-bit relaunch. NinjaOne runs 32-bit; HKLM\SOFTWARE\Veeam is hidden
# --- under WOW64 redirection. Must precede transcript.
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -and -not [Environment]::Is64BitProcess) {
    $sysNative = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysNative) {
        & $sysNative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- Constants ---------------------------------------------------------------
$TargetBuild        = [version]'13.1.0.411'   # the last build reachable by a full ISO
$PatchTargetBuild   = [version]'13.1.1.18'    # reachable ONLY by the patch, and ONLY from 13.1.0.411
$PatchBaseBuild     = [version]'13.1.0.411'   # the patch refuses anything else
$GateBuild          = [version]'12.3.1.1139'    # Veeam KB4763 - the v13 floor
$Ps7RequiredBuild   = [version]'13.0.0.0'
$StagingFolderName  = 'VeeamInstall'
$script:IsoFolder   = $null
$InstallerRelPath   = 'Setup\Silent\Veeam.Silent.Install.exe'
$OrgName            = if ($env:orgName) { ([string]$env:orgName).Trim() } else { 'ORG' }
$LogFolder          = Join-Path $env:ProgramData "$OrgName\Logs\VeeamUpgrade"
$StateFile          = Join-Path $LogFolder 'upgrade-state.json'
$BaselineFile       = Join-Path $LogFolder 'baseline.json'
$CopyWatchFile      = Join-Path $LogFolder 'copy-watch.json'
$FailureActionsFile = Join-Path $LogFolder 'svc-failure-actions.json'
$DbReportFile       = Join-Path $LogFolder 'VbrDatabaseIssuesSetupReport.xml'
$JobStateFile       = Join-Path $LogFolder 'jobs-paused.json'
$WedgeMarkerFile    = Join-Path $LogFolder 'wedge-reboot.json'
$StopRetryFile      = Join-Path $LogFolder 'stop-retry.json'
$StuckRescanMinutes = 15      # a STARTINFRARESCAN older than this will never finish
$SelfHealMarkerFile = Join-Path $LogFolder 'jobs-selfhealed.json'
$SetupTempFolder    = 'C:\ProgramData\Veeam\Setup\Temp'
$DefaultVeeamLogDir = 'C:\ProgramData\Veeam\Backup'
$MinFreeGBUnstaged  = 45      # staging volume, ISO not yet present
$MinFreeGBStaged    = 25      # staging volume, ISO already there
$MinFreeGBSystem    = 30      # C: for the PATCH track - no evidence the patch needs more.
$MinFreeGBSystemHop = 33      # C: for a full HOP. Setup asked for exactly 32.27 GB on <SERVER03> and <SERVER20> (event 105).
                              # 35 was too high: it halted <SERVER01>/<SERVER02>/<SERVER03>/<SERVER04>
                              # at 31.8/33.8/34.0/29.8 GB free, all of which had enough.
$LogRetention       = 10
$MutexName          = "Global\$OrgName-VeeamUpgrade"
$RestSvcTimeoutMs   = 180000
$RebootDelaySeconds = 60
$SvcWaitAttempts    = 10
$SvcWaitSeconds     = 30
$CopyWatchHours     = 24
$SvcStartSettleSecs = 25
# VeeamBackupSvc stops its own running jobs on shutdown and allows itself
# StopAllRunningJobsTimeout = 00:10:00 to do it (visible in Svc.VeeamBackup.log
# under "Service options"). A 600 s budget therefore gave up at the exact
# moment the service would have finished. 900 s leaves headroom.
$SvcStopTimeoutSecs = 900
$StopPendingGraceSecs = 45
$StopWorkerGraceSecs  = 300   # leave the service to drain before touching workers
$AgentUpgradeWaitSecs = 600
$MaxInstallAttempts   = 2
$SessionTrimCount     = 500
$MaxStdoutLines       = 25   # stderr only; stdout is filtered to the useful lines
$MaxResultXmlLines    = 30
$MaxLineChars         = 300
$TaskLaunchWaitSecs   = 60
$SessionDrainWaitSecs = 1800    # how long to wait for running jobs to finish
$SessionPollSecs      = 30
$SelfHealRecentDays   = 30    # a disabled job with no session in this window is left alone
$WedgeGraceSecs       = 180   # how long a *Pending state must PERSIST to count
$WedgePollSecs        = 15
$ComponentWaitSecs    = 900
$RpBackwardsToleranceHours = 26   # one missed hourly cycle during a reboot
$RpCountTolerancePct       = 0.90 # a drop below this is more than retention

$InstallAdminUser   = if ($env:installAdminUser) { ([string]$env:installAdminUser).Trim() } else { '<LOCAL_ADMIN>' }
$LapsFieldName      = if ($env:lapsFieldName) { ([string]$env:lapsFieldName).Trim() } else { 'lapsPassword' }
# Written by this script at the end of EVERY run. Device-local and immediate -
# the only fleet signal in this project that does not lag, truncate or page.
# CREATE IT FIRST in NinjaOne: device custom field, type Text, scriptable
# read/write, named exactly veeamUpgradeState. One v2/queries/custom-fields
# call then reads the true state of every BDR.
$StateFieldName     = 'veeamUpgradeState'
$ScriptVersionTag   = '4.53'
$InstallTaskName    = 'VeeamUpgrade-Installer'

# Verbs the watchdog may terminate. STARTINFRARESCAN, STARTHVCTPRESCAN and
# STARTDISCOVER are deliberately ABSENT - they are dispatcher-managed and
# killing one makes it worse, not better. From <SERVER56>'s service log:
#   "New rescan job will be started. Reason: Session ... for previous
#    infrastructure rescan job was stopped."
# The watchdog killed STARTINFRARESCAN nine times in ten minutes and the
# service spawned a fresh session each time - the watchdog was CAUSING the
# respawn it was trying to clear. Left alone, the same rescan completed in
# 50 seconds with Session result: "Success", and the infrastructure was
# entirely healthy (3 servers, 3 repositories, all IsUnavailable False).
# The remaining verbs are one-shot workers that do not get re-dispatched.
# STARTCHECKPOINTREMOVAL removed in v4.23: it was terminated 4 times per run on
# <SERVER49> and <SERVER50> and respawned with a new PID within 20 seconds every
# time, exactly like STARTINFRARESCAN. Every dispatcher-managed verb is now out
# of this list.
$MaintenanceVerbs = 'STARTRESYNC|STARTDBMAINTENANCE|STARTCATCLEANUP|STARTAUDITZIP|STARTRETENTION'

# --- RMM inputs ----------------------------------------------------------------
$DownloadUrlV13 = $env:downloadUrlV13
$SaveFileV13    = $env:saveFileV13
$Sha256V13      = $env:sha256V13
$DownloadUrlV12 = $env:downloadUrlV12
$SaveFileV12    = $env:saveFileV12
$Sha256V12      = $env:sha256V12
$AutoUpgrade    = if ($env:vbrAutoUpgrade -eq '1') { '1' } else { '0' }
$PreflightOnly  = ($env:preflightOnly -eq '1')
$UpgradeComponents = -not ($env:upgradeComponents -eq '0')
# JOB PAUSING IS ON. It has to be: without it the install waits for a quiet
# window that may never arrive on an hourly-backup site, the device loops
# failing runs, and the office goes unprotected for longer than the upgrade
# would have taken.
#
# The pausing was never the problem. The RESTORE was - it depended on a state
# file that could be lost, overwritten with an all-disabled baseline, or
# misread. That single fragility caused all three incidents (v4.7, v4.18,
# v4.20). As of v4.24 the restore does not depend on that file:
#   - the job names are held in memory for the life of the run
#   - every exit path re-enables from memory first, file second
#   - anything still disabled at exit is re-enabled outright
# Set pauseJobsDuringUpgrade=0 only to rule the pause in or out while
# diagnosing something.
$PauseJobs      = -not ($env:pauseJobsDuringUpgrade -eq '0')
# The Veeam console is a UI process. Holding it open blocks an upgrade that is
# otherwise ready, and 8-9 devices sat on this gate every wave. Closing it
# loses only an unsaved console session. Set closeConsole=0 to halt instead.
$CloseConsole   = -not ($env:closeConsole -eq '0')
# Extended disk reclaim: Windows Update cache, CBS logs, %TEMP%, WinSxS.
$DeepDiskClean  = -not ($env:deepDiskClean -eq '0')
# A BDR whose VeeamBackupSvc is set to Disabled backs up nothing and never
# will. Re-enable it rather than only reporting. Set fixDisabledServices=0 to
# report without changing the start type.
$FixDisabledSvc = -not ($env:fixDisabledServices -eq '0')
# A validation failure that is ONLY a restore-point count drop, with every
# job, repository and backup object still present, does not describe data
# loss - it describes retention rolling a chain or a job being renamed.
# Holding those devices stops them reaching the latest patch, and every day a
# BDR sits behind is a day its workstations are not protected. Set
# holdOnPointDrop=1 to restore the old always-hold behaviour.
$HoldOnPointDrop = ($env:holdOnPointDrop -eq '1')

# Job names this run disabled. THE AUTHORITATIVE RECORD - a file can be lost,
# this cannot, for as long as the process lives.
$script:PausedJobNames = @()
$script:PatchVerified  = $false
# What this run will record in the custom field. Set at each terminal point;
# the finally block writes whatever is current.
$script:StateForField       = $null
$script:StateDetailForField = ''
if ($env:sessionWaitMinutes -and [int]::TryParse($env:sessionWaitMinutes, [ref]$null)) {
    $SessionDrainWaitSecs = ([int]$env:sessionWaitMinutes) * 60
}
$StaleAgentDays = 180
if ($env:staleAgentDays -and [int]::TryParse($env:staleAgentDays, [ref]$null)) {
    $StaleAgentDays = [int]$env:staleAgentDays
}
$StaleRestorePointDays = 60
if ($env:staleRestorePointDays -and [int]::TryParse($env:staleRestorePointDays, [ref]$null)) {
    $StaleRestorePointDays = [int]$env:staleRestorePointDays
}
$DownloadUrlPatch = $env:downloadUrlPatch
$SaveFilePatch    = $env:saveFilePatch
$Sha256Patch      = $env:sha256Patch
$PatchArgs        = if ($env:patchArgs) { [string]$env:patchArgs } else { '/silent /noreboot' }
$EnablePatch      = ($env:enablePatch -eq '1')
# COPY-WATCH NO LONGER HOLDS BY DEFAULT.
# The purpose of this script is to get a BDR onto the latest build. Veeam agents
# on the protected endpoints are already being moved forward by WinGet, and a
# BDR left on an older build cannot accept them - so a stale build is the more
# urgent problem, and an unverified offsite copy is not a reason to leave one
# behind. The watch FILE is still written and retained, so the copy is still
# checked and still reported; it simply does not stop the box progressing.
# Set holdForCopyWatch=1 to restore the old blocking behaviour.
$HoldForCopyWatch = ($env:holdForCopyWatch -eq '1')
# The PATCH track does NOT stop services by default. See the header note.
$StopSvcForPatch  = ($env:stopServicesForPatch -eq '1')

$VeeamLogRetentionDays = 30
if ($env:veeamLogRetentionDays -and [int]::TryParse($env:veeamLogRetentionDays, [ref]$null)) {
    $VeeamLogRetentionDays = [int]$env:veeamLogRetentionDays
}

# --- State ---------------------------------------------------------------------
$exitCode   = 0
$mutex      = $null
$haveMutex  = $false
$mountedIso = $null
$gates      = New-Object System.Collections.Generic.List[psobject]
$AdminPassword = $null
$script:PwshPath = $null

function Write-Log {
    # MUST be Write-Host. Write-Output puts log text on the pipeline, so lines
    # emitted inside a function whose return value is assigned get captured into
    # that value (this once made the installer exit code an array).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost','',
        Justification='Write-Host is required, not incidental. Write-Output puts log text on the pipeline, so a log line emitted inside a function whose return value is assigned becomes part of that value - this once turned the installer exit code into an array. NinjaOne also captures the host stream.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Write-Log is the script-library logging shim. The target host is Windows PowerShell 5.1, which has no built-in Write-Log; the analyzer flags it against a newer runtime list.')]
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

function Reset-WedgedBackupService {
    # A VeeamBackupSvc STUCK IN StopPending WITH NO WORKERS LEFT IS NOT DRAINING
    # ANYTHING - IT IS SPINNING. <SERVER26>, 2026-10-01: its own log
    # repeated "[CAgentCloseExecuter] An error occurred during asynchronious
    # agent closing / Safe handle has been closed" 2,058 times in 3,000 lines,
    # rotating four 10 MB logs in three seconds. It can never finish stopping,
    # and while it sits there the Veeam API cannot be reached, so paused jobs
    # cannot be restored and the practice stays dark - which is how <SERVER26> went
    # most of a day with all six jobs off. The exit guard only restarted
    # services reading Stopped, and StopPending is not Stopped.
    # Ending the service process and starting it fresh brought <SERVER26> straight
    # back by hand. This does the same - FOR RECOVERY ONLY:
    #   - never while the one-shot installer task or Veeam's silent installer
    #     is running (killing it mid-install is what wedged the August pilot,
    #     when SCM auto-restart brought it back under the installer);
    #   - never while a Veeam.Backup.Manager.exe worker is still alive - that
    #     is the worker-kill's case, not this one;
    #   - never to push an install through. Installs still need a graceful stop.
    # Returns $true if VeeamBackupSvc is Running afterwards.
    $svc = Get-CimInstance Win32_Service -Filter "Name='VeeamBackupSvc'" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.State -ne 'Stop Pending' -or -not $svc.ProcessId) { return $false }
    $installing = $false
    try { if (@(Get-ScheduledTask -TaskName $InstallTaskName -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }).Count -gt 0) { $installing = $true } } catch { }
    if (@(Get-Process -Name 'Veeam.Silent.Install' -ErrorAction SilentlyContinue).Count -gt 0) { $installing = $true }
    if ($installing) {
        Write-Log 'VeeamBackupSvc is in StopPending, but an installer is still running - leaving the service alone.' 'WARN'
        return $false
    }
    $workers = @(Get-CimInstance Win32_Process -Filter "Name='Veeam.Backup.Manager.exe'" -ErrorAction SilentlyContinue)
    if ($workers.Count -gt 0) { return $false }
    try {
        $logf = Join-Path $env:ProgramData 'Veeam\Backup\Svc.VeeamBackup.log'
        if (Test-Path -LiteralPath $logf) {
            $top = Get-Content -LiteralPath $logf -Tail 1500 -ErrorAction SilentlyContinue |
                   ForEach-Object { (($_ -replace '^\[[^\]]*\]\s*<\s*\d+>\s*', '') -replace '\d+', '#').Trim() } |
                   Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
            if ($top -and $top.Count -gt 50) {
                $msg = [string]$top.Name; if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) }
                Write-Log ("  The service log is repeating one message {0} times in its last 1,500 lines: {1}" -f $top.Count, $msg) 'WARN'
            }
        }
    } catch { }
    Write-Log ("VeeamBackupSvc is stuck in StopPending with no workers (PID {0}) and cannot finish stopping. Ending the service process so it can start fresh and the jobs can be restored." -f $svc.ProcessId) 'WARN'
    try { Stop-Process -Id $svc.ProcessId -Force -ErrorAction Stop }
    catch { Write-Log "  Could not end PID $($svc.ProcessId): $($_.Exception.Message)" 'ERROR'; return $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Seconds 5
        $st = [string](Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
        if ($st -in @('Stopped','Running','StartPending')) { break }
    }
    try { Start-Service -Name 'VeeamBackupSvc' -ErrorAction Stop } catch { }
    try { Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs } catch { }
    $st = [string](Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
    if ($st -eq 'Running') { Write-Log 'VeeamBackupSvc is running again after the reset.' }
    else { Write-Log "VeeamBackupSvc is '$st' after the reset - THIS DEVICE NEEDS A PERSON, and its jobs may still be paused." 'ERROR' }
    return ($st -eq 'Running')
}

function Get-RebootMarker {
    # A reboot this script did for a named reason, and whether the box has
    # booted since - so a cause that SURVIVES a reboot is reported for a
    # person instead of being rebooted for on every run.
    param([string]$Name)
    $f = Join-Path $LogFolder "reboot-$Name.json"
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try {
        $m    = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
        # Windows PowerShell keeps the stored value as ISO text; PowerShell 7
        # turns it into a date. Read both as UTC, or the once-only check could
        # misjudge by the time-zone offset.
        $raw  = $m.rebootedUtc
        $at   = if ($raw -is [datetime]) { $raw.ToUniversalTime() } else {
                    [datetime]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture,
                        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)) }
        return [pscustomobject]@{ rebootedUtc = $at.ToString('o'); rebootedSince = ($boot -gt $at) }
    } catch { return $null }
}

function Set-RebootMarker {
    param([string]$Name)
    try {
        [pscustomobject]@{ rebootedUtc = (Get-Date).ToUniversalTime().ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LogFolder "reboot-$Name.json") -Encoding UTF8 -Force
    } catch { }
}

function Clear-RebootMarker {
    param([string]$Name)
    Remove-Item -LiteralPath (Join-Path $LogFolder "reboot-$Name.json") -Force -ErrorAction SilentlyContinue
}

function Wait-VeeamJobApi {
    # A REAL ANSWER FROM VEEAM, NOT A CHILD PROCESS THAT HAPPENS TO START.
    # The old probe returned ok=$true without calling Veeam at all, so it could
    # report the API up while every Get-VBRJob was being refused - which is
    # exactly what happened on <SERVER30> on 2026-09-29 between 17:31 and
    # 17:37 ("No connection could be made ... 127.0.0.1:9396").
    # Returns the seconds it took, or -1 if Veeam never answered.
    param([int]$TimeoutSeconds = 180)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $probe = $null
        try {
            $probe = Invoke-VeeamQuery -Script @'
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) { try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { } }
  $null = @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)
  @{ ok = $true } | ConvertTo-Json -Compress
} catch { @{ ok = $false; error = [string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
        } catch { }
        if ($probe -and $probe.ok) { return [int]$sw.Elapsed.TotalSeconds }
        Start-Sleep -Seconds 10
    }
    return -1
}

function Get-PausedJobsStillDisabled {
    # Which of the named jobs are still disabled - or $null if their state
    # cannot be read. $null is deliberately NOT the same as "none": a check
    # that could not run has confirmed nothing.
    # RETURNS AN OBJECT, NOT A BARE LIST. PowerShell unrolls a returned array,
    # so an EMPTY list comes back as $null - which made "no jobs still
    # disabled" indistinguishable from "could not read the jobs" and blocked
    # every reboot, healthy ones included. Caught by test before shipping.
    param([string[]]$Names)
    if (@($Names).Count -eq 0) { return [pscustomobject]@{ Readable = $true; Off = @() } }
    $lit = '@(' + ((@($Names) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ')'
    $body = @'
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) { try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { } }
  $off = @()
  foreach ($j in @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)) {
    if ($want -notcontains [string]$j.Name) { continue }
    $en = $false
    foreach ($p in @('IsScheduleEnabled','JobEnabled','Enabled','IsEnabled')) { if ($j.PSObject.Properties.Name -contains $p) { $en = [bool]$j.$p; break } }
    if (-not $en) { $off += [string]$j.Name }
  }
  @{ ok = $true; off = @($off) } | ConvertTo-Json -Compress
} catch { @{ ok = $false; error = [string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@
    $r = $null
    try { $r = Invoke-VeeamQuery -Script ('$want = ' + $lit + [Environment]::NewLine + $body) } catch {
        return [pscustomobject]@{ Readable = $false; Off = @() }
    }
    if (-not $r -or -not $r.ok) { return [pscustomobject]@{ Readable = $false; Off = @() } }
    return [pscustomobject]@{ Readable = $true; Off = @($r.off | Where-Object { $_ }) }
}

function Invoke-ForcedReboot {
    param([string]$Reason)
    # NEVER REBOOT WITH JOBS THIS RUN PAUSED STILL DISABLED - AND FAIL CLOSED.
    # Every one of the six reboots in this script comes through here. The old
    # version tried a restore and rebooted whatever the result. The v4.48 guard
    # covered only one of the six paths, and it treated "could not read the
    # jobs" as "nothing is disabled".
    # <SERVER30>, 2026-09-29: Get-VBRJob was refused on 127.0.0.1:9396,
    # both restores failed, the log read "JOBS MAY STILL BE PAUSED" - and it
    # force-rebooted anyway at 17:36:17, which also killed the exit guard
    # while it was still restarting services.
    # Now, before ANY reboot, if this run paused jobs: bring the services up,
    # wait for Veeam to genuinely answer a job query, restore, then VERIFY. If
    # the jobs cannot be confirmed re-enabled - including when their state
    # cannot be read at all - the reboot is skipped, the run exits 2, and the
    # exit guard gets to finish the restore. A delayed hop is recoverable; a
    # practice rebooted into having no backups is not.
    if (@($script:PausedJobNames).Count -gt 0) {
        $names = @($script:PausedJobNames)
        Write-Log ("Before rebooting ({0}): {1} job(s) this run paused must be confirmed re-enabled first: {2}" -f $Reason, $names.Count, ($names -join ', ')) 'WARN'
        try { Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs } catch { Write-Log "Service start before reboot failed: $($_.Exception.Message)" 'WARN' }
        $apiSecs = Wait-VeeamJobApi -TimeoutSeconds 180
        if ($apiSecs -ge 0) { Write-Log "Veeam answered a job query after $apiSecs s." }
        else { Write-Log 'Veeam did not answer a job query within 180 s.' 'WARN' }
        try { Restore-PausedJobsFromMemory } catch { Write-Log "Memory restore before reboot failed: $($_.Exception.Message)" 'ERROR' }
        try { Restore-VeeamJobs } catch { Write-Log "Job restore before reboot failed: $($_.Exception.Message)" 'ERROR' }
        $chk = Get-PausedJobsStillDisabled -Names $names
        $stillOff = @($chk.Off)
        if (-not $chk -or -not $chk.Readable) {
            Write-Log ("NOT REBOOTING. The {0} job(s) this run paused could not be read back from Veeam, so they cannot be confirmed re-enabled: {1}. The reboot ({2}) is skipped and the exit guard will keep restoring. If this repeats, this device needs a person." -f `
                $names.Count, ($names -join ', '), $Reason) 'ERROR'
            $script:exitCode = 2
            exit 2
        }
        if (@($stillOff).Count -gt 0) {
            Write-Log ("NOT REBOOTING. {0} job(s) this run paused are still disabled: {1}. The reboot ({2}) is skipped so this site is not left without backups." -f `
                @($stillOff).Count, (@($stillOff) -join ', '), $Reason) 'ERROR'
            $script:exitCode = 2
            exit 2
        }
        Write-Log ("Confirmed with Veeam: all {0} job(s) this run paused are enabled." -f $names.Count)
        $script:PausedJobNames = @()
    }
    Write-Log "REBOOTING (forced) in $RebootDelaySeconds s: $Reason" 'WARN'
    & shutdown.exe /r /f /t $RebootDelaySeconds /c "Veeam upgrade - $Reason" /d p:4:1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "shutdown.exe exited $LASTEXITCODE - falling back to Restart-Computer -Force." 'WARN'
        try { Stop-Transcript | Out-Null } catch { }
        if ($script:haveMutexRef) { try { $script:haveMutexRef.ReleaseMutex() } catch { } }
        Restart-Computer -Force
    }
}

function Write-CappedLines {
    # Bounded excerpt to the activity log; full text stays on disk. NinjaOne
    # truncates long stdout, and installer stderr is UTF-16 (every character
    # space-separated) so a LINE cap alone was not enough - cap characters too.
    param([string[]]$Lines, [int]$Max, [string]$Prefix, [string]$FullPath)
    $l = @($Lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object {
        $t = $_.Trim()
        if ($t.Length -gt $MaxLineChars) { $t.Substring(0, $MaxLineChars) + ' ...[truncated]' } else { $t }
    })
    if ($l.Count -le $Max) { foreach ($x in $l) { Write-Log "$Prefix$x" }; return }
    $head = [math]::Floor($Max / 2); $tail = $Max - $head
    for ($i = 0; $i -lt $head; $i++) { Write-Log "$Prefix$($l[$i])" }
    Write-Log "$Prefix... [$($l.Count - $Max) lines omitted - full text in $FullPath] ..."
    for ($i = $l.Count - $tail; $i -lt $l.Count; $i++) { Write-Log "$Prefix$($l[$i])" }
}

function Add-Gate {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $gates.Add([pscustomobject]@{ Gate = $Name; Pass = $Pass; Detail = $Detail })
}

function Test-PortListening {
    # Get-NetTCPConnection -State Listen returns nothing intermittently on a box
    # with a large connection table - confirmed <SERVER17>, where netstat
    # showed 0.0.0.0:9392 LISTENING (PID 1348) while the filtered cmdlet came
    # back empty amid ~40 TIME_WAIT entries. netstat is authoritative here.
    param([int]$Port)
    try {
        if (@(& netstat.exe -ano | Select-String ":$Port\s.*LISTENING").Count -gt 0) { return $true }
    } catch { }
    try {
        return (@(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
                  Where-Object { $_.State -eq 'Listen' }).Count -gt 0)
    } catch { return $false }
}

function Get-PortOwner {
    param([int]$Port)
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
             Where-Object { $_.State -eq 'Listen' } | Select-Object -First 1
        if ($c) { return (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
        $line = @(& netstat.exe -ano | Select-String ":$Port\s.*LISTENING") | Select-Object -First 1
        if ($line) {
            $procId = ($line.ToString().Trim() -split '\s+')[-1]
            if ($procId -match '^\d+$') { return (Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue).ProcessName }
        }
    } catch { }
    return $null
}

function Get-InstalledVbrBuild {
    $keyPath = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'
    if (-not (Test-Path -LiteralPath $keyPath)) { throw 'Veeam Backup & Replication is not installed (no registry key).' }
    $k = Get-ItemProperty -LiteralPath $keyPath
    if ($k.PSObject.Properties.Name -notcontains 'CorePath') { throw 'Veeam registry key has no CorePath.' }
    $core = [string]$k.CorePath
    $exe  = Join-Path $core 'Veeam.Backup.Service.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Veeam.Backup.Service.exe not found at $core" }
    $raw = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion.Trim()
    $v = $null
    if (-not [version]::TryParse(($raw -split '\s')[0], [ref]$v)) { throw "Could not parse build string '$raw'." }
    return @{ Build = $v; CorePath = $core }
}

function Get-VbrProductArpVersion {
    # THE ONLY FIELD THE 13.1.1.18 PATCH ACTUALLY MOVES.
    #
    # Confirmed on <SERVER47> immediately after a successful patch
    # (VeeamBackupAndReplication13Patch#1 log, 653 KB, "Return value 0."):
    #
    #   Veeam Backup & Replication            13.1.1.18   <-- moves
    #   Veeam Backup & Replication Server     13.1.0.411  <-- does NOT
    #   Veeam Backup & Replication Console    13.1.0.411  <-- does NOT
    #   Veeam.Backup.Service.exe file version 13.1.0.411  <-- does NOT
    #
    # Four detection attempts got this wrong before the evidence was in hand:
    #   v4.17 file version only    - never moves, so a patched box re-patched
    #   v4.19 Updater Plug-in      - ships at 13.1.1.18 inside the 13.1.0.411
    #                                ISO, so it flagged 184 unpatched devices
    #                                as already done
    #   v4.30 product file version - same as v4.17; FATAL'd 7 devices that had
    #                                patched perfectly well
    #   this  the bare "Veeam Backup & Replication" ARP row
    #
    # Match the bare product name ONLY - anchored, and explicitly not the
    # Server, Console, Catalog or any other suffixed row.
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    try {
        $e = Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match '^Veeam Backup \& Replication$' } |
             Select-Object -First 1
        if ($e) { return [string]$e.DisplayVersion }
    } catch { }
    return $null
}

function Get-VbrArpVersion {
    # ARP freezes at the BASE build while patches advance the file version
    # (fleet: file 12.3.2.4165 vs ARP 12.3.2.3617 on 16 devices). Normal, but
    # logged - it was a candidate explanation for boundary-build failures,
    # since disproved on <SERVER18> where both agreed.
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    try {
        $e = Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match '^Veeam Backup & Replication Server' } |
             Select-Object -First 1
        if ($e) { return [string]$e.DisplayVersion }
    } catch { }
    return $null
}

function Get-PwshPath {
    if ($script:PwshPath) { return $script:PwshPath }
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($c) { $script:PwshPath = $c.Source; return $script:PwshPath }
    foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe")) {
        if (Test-Path -LiteralPath $p) { $script:PwshPath = $p; return $script:PwshPath }
    }
    return $null
}

function Resolve-StagingFolder {
    # Small C: (109-117 GB on eight fleet boxes) beside a multi-TB repository
    # volume. 36 GB of staging does not fit on C: at any cleanup level, so it
    # goes to the fixed volume with the most free space, at the VOLUME ROOT -
    # beside a repository, never inside one.
    $vols = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
              Sort-Object FreeSpace -Descending)
    if ($vols.Count -eq 0) { return "C:\$StagingFolderName" }
    $pick = $vols[0]
    $summary = ($vols | ForEach-Object { "$($_.DeviceID) $([math]::Round($_.FreeSpace/1GB,1))GB" }) -join ', '
    Write-Log ("Volumes: {0}. Staging on {1} (most free)." -f $summary, $pick.DeviceID)
    return (Join-Path "$($pick.DeviceID)\" $StagingFolderName)
}

function Get-AllStagingFolders {
    $out = @()
    foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        $p = Join-Path "$($v.DeviceID)\" $StagingFolderName
        if (Test-Path -LiteralPath $p) { $out += $p }
    }
    return ,$out
}

function Remove-StaleInstallMedia {
    param([string]$KeepIsoName, [string]$KeepSrcFolder)
    foreach ($folder in (Get-AllStagingFolders)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter '*.iso' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -eq $KeepIsoName -and $folder -eq $script:IsoFolder) { continue }
            $mb = [math]::Round($f.Length / 1MB, 0)
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $f.FullName)) {
                Write-Log ("Reclaimed stale ISO {0} ({1} MB) from {2}." -f $f.Name, $mb, $folder) 'WARN'
            }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath $folder -Directory -Filter 'src*' -ErrorAction SilentlyContinue)) {
            if ($d.FullName -eq $KeepSrcFolder) { continue }
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $d.FullName)) { Write-Log "Reclaimed stale install source $($d.FullName)." 'WARN' }
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter '*.partial' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Removed orphaned partial download $($f.FullName)." 'WARN'
        }
    }
}

function Remove-AllStagedMedia {
    foreach ($folder in (Get-AllStagingFolders)) {
        foreach ($f in @($SaveFileV13, $SaveFileV12)) {
            if (-not $f) { continue }
            $p = Join-Path $folder $f
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Write-Log "Removed $p" }
        }
        Get-ChildItem -LiteralPath $folder -Directory -Filter 'src*' -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed local install source $($_.FullName)"
        }
    }
}

function Invoke-DeepDiskClean {
    # LAST RESORT RECLAIM, ONLY WHEN C: IS BELOW THE GATE.
    # Veeam setup needs ~29.3 GB on C: regardless of where the ISO is staged.
    # Five devices sat on SystemDriveFreeSpace through every wave of the
    # 2026-09-23 project with 21-27 GB free on 109-117 GB drives and their
    # Veeam log trees already pruned - the easy reclaim was spent.
    #
    # Everything below is genuinely disposable: the Windows Update download
    # cache rebuilds on demand, CBS logs are servicing history, TEMP is
    # temporary by definition, and DISM /StartComponentCleanup removes
    # superseded component versions. NOTHING here touches Veeam data, backups,
    # repositories or the page file.
    # (4.51) Four more, each done by hand first on <SERVER03>, <SERVER06> and
    # <SERVER20> before being trusted here: the Delivery Optimization cache, Veeam
    # LOGS older than 7 days (never a repository path), Veeam setup logs from
    # earlier attempts, and hibernation - a BDR never sleeps, and hiberfil.sys
    # is several GB of C: on a 16 GB box.
    param([double]$NeedGB, [string[]]$RepoPaths = @())
    $before = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
    Write-Log "Deep disk clean starting - C: has $before GB free, gate needs $NeedGB GB." 'WARN'
    $freed = @()

    try {
        $sd = Join-Path $env:WINDIR 'SoftwareDistribution\Download'
        if (Test-Path -LiteralPath $sd) {
            $sz = [math]::Round((Get-ChildItem -LiteralPath $sd -Recurse -Force -ErrorAction SilentlyContinue |
                   Measure-Object Length -Sum).Sum / 1GB, 2)
            if ($sz -gt 0.1) {
                Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                Get-ChildItem -LiteralPath $sd -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Start-Service -Name wuauserv -ErrorAction SilentlyContinue
                $freed += "Windows Update cache $sz GB"
            }
        }
    } catch { Write-Log "  Windows Update cache: $($_.Exception.Message)" 'WARN' }

    try {
        $cbs = Join-Path $env:WINDIR 'Logs\CBS'
        if (Test-Path -LiteralPath $cbs) {
            $old = @(Get-ChildItem -LiteralPath $cbs -File -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) })
            if ($old.Count -gt 0) {
                $sz = [math]::Round(($old | Measure-Object Length -Sum).Sum / 1GB, 2)
                $old | Remove-Item -Force -ErrorAction SilentlyContinue
                if ($sz -gt 0.05) { $freed += "CBS logs $sz GB" }
            }
        }
    } catch { }

    foreach ($t in @($env:TEMP, (Join-Path $env:WINDIR 'Temp'))) {
        try {
            if (-not (Test-Path -LiteralPath $t)) { continue }
            $old = @(Get-ChildItem -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) })
            if ($old.Count -gt 0) {
                $sz = [math]::Round(($old | Measure-Object Length -Sum).Sum / 1GB, 2)
                $old | Remove-Item -Force -ErrorAction SilentlyContinue
                if ($sz -gt 0.05) { $freed += "$t $sz GB" }
            }
        } catch { }
    }

    try {
        if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
            Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue | Out-Null
            $freed += 'Delivery Optimization cache'
        }
    } catch { }

    # The routine prune keeps 30 days; when C: is short a week of logs is still
    # enough to troubleshoot from. Remove-OldVeeamLogs never touches a repo path.
    try { Remove-OldVeeamLogs -RetentionDays 7 -RepoPaths $RepoPaths } catch { Write-Log "  Veeam log prune (7 days): $($_.Exception.Message)" 'WARN' }

    # Setup logs from earlier attempts. This run's are kept - the failure
    # capture reads them.
    try {
        if (Test-Path -LiteralPath $SetupTempFolder) {
            $old = @(Get-ChildItem -LiteralPath $SetupTempFolder -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-2) })
            if ($old.Count -gt 0) {
                $sz = [math]::Round(($old | Measure-Object Length -Sum).Sum / 1GB, 2)
                $old | Remove-Item -Force -ErrorAction SilentlyContinue
                if ($sz -gt 0.05) { $freed += "old Veeam setup logs $sz GB" }
            }
        }
    } catch { }

    try {
        if (Test-Path -LiteralPath (Join-Path $env:SystemDrive 'hiberfil.sys')) {
            & powercfg.exe /hibernate off 2>&1 | Out-Null
            $freed += 'hibernation file (hibernation turned off - a BDR never sleeps)'
        }
    } catch { }

    try {
        Write-Log '  Running DISM /StartComponentCleanup (can take several minutes) ...'
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet 2>&1 | Out-Null
        Write-Log "  DISM exit $LASTEXITCODE."
    } catch { Write-Log "  DISM: $($_.Exception.Message)" 'WARN' }

    $after = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
    Write-Log ("Deep disk clean done - C: {0} GB -> {1} GB (reclaimed {2} GB).{3}" -f `
        $before, $after, [math]::Round($after - $before, 1),
        $(if ($freed.Count) { ' ' + ($freed -join '; ') } else { '' })) 'WARN'
    return $after
}

function Remove-OldVeeamLogs {
    # C:\ProgramData\Veeam\Backup was 58.47 GB / 12,522 files on <SERVER17>,
    # oldest 2024-04-11 - the real cause of the FreeSpace halts, and invisible
    # to a plain directory scan because ProgramData is hidden. Active logs are
    # recent by definition, so an age filter never touches them.
    # SAFETY: folder read from Veeam's own LogDirectory value; abandoned
    # entirely if that path sits inside a backup repository.
    param([int]$RetentionDays, [string[]]$RepoPaths = @())
    if ($RetentionDays -le 0) { Write-Log 'Veeam log pruning disabled (veeamLogRetentionDays=0).'; return }

    $dir = $null
    try {
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication' -ErrorAction SilentlyContinue
        foreach ($n in @('LogDirectory','LogsDirectory')) {
            if ($k -and $k.PSObject.Properties.Name -contains $n -and $k.$n) { $dir = [string]$k.$n; break }
        }
    } catch { }
    if (-not $dir) { $dir = $DefaultVeeamLogDir }
    if (-not (Test-Path -LiteralPath $dir)) { return }

    foreach ($rp in @($RepoPaths)) {
        if ($rp -and $dir.TrimEnd('\').ToLower().StartsWith($rp.TrimEnd('\').ToLower())) {
            Write-Log "Veeam log folder '$dir' sits inside repository path '$rp' - pruning SKIPPED (backup data protection)." 'WARN'
            return
        }
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $old = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Include '*.log','*.zip','*.etl' -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($old.Count -eq 0) { Write-Log "Veeam logs at $dir : nothing older than $RetentionDays days."; return }

    $gb = [math]::Round((($old | Measure-Object Length -Sum).Sum) / 1GB, 2)
    $oldest = ($old | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
    Write-Log ("Veeam log prune: {0} file(s), {1} GB, older than {2} days (oldest {3}) in {4} ..." -f $old.Count, $gb, $RetentionDays, $oldest, $dir) 'WARN'
    $removed = 0
    foreach ($f in $old) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $f.FullName)) { $removed++ }
    }
    Write-Log ("Veeam log prune complete: {0} of {1} file(s) removed (~{2} GB reclaimed)." -f $removed, $old.Count, $gb) 'WARN'
}

# =============================================================================
# VEEAM POWERSHELL - DUAL RUNTIME
# =============================================================================

function Invoke-VeeamQuery {
    param([Parameter(Mandatory)][string]$Script, [string]$Prefix = '')

    $build = $null
    try { $build = (Get-InstalledVbrBuild).Build } catch { }
    $needPwsh = ($build -and $build -ge $Ps7RequiredBuild)

    $body = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$WarningPreference = 'SilentlyContinue'
`$InformationPreference = 'SilentlyContinue'
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop
$Prefix
$Script
"@

    $txt = $null
    if (-not $needPwsh) {
        $out = & ([scriptblock]::Create($body))
        $txt = (@($out) | Where-Object { $_ -ne $null } | ForEach-Object { [string]$_ }) -join "`n"
    } else {
        $pw = Get-PwshPath
        if (-not $pw) {
            throw "PowerShell 7 (pwsh.exe) not found. VBR $build requires it for the Veeam PowerShell module (v13 is .NET Core)."
        }
        $tmp = Join-Path $LogFolder ("veeamq_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8 -Force
        try {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $raw = & $pw -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>&1
            $rc  = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            $good = @($raw) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }
            $bad  = @($raw) | Where-Object { $_ -is  [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }
            $txt  = ($good -join "`n")
            if ([string]::IsNullOrWhiteSpace($txt)) { throw "pwsh Veeam query returned no output (exit $rc). $($bad -join '; ')" }
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    # Veeam cmdlets can emit WARNING text onto the same stream as the payload -
    # v13 does exactly that for the deprecated Disable-VBRJob. Taking the FIRST
    # brace in the buffer therefore fed warning text to ConvertFrom-Json, which
    # threw; in the job-pause path that exception skipped the restore and left
    # three sites with their backups disabled. Every query here emits its JSON
    # as a single compressed line, so take the LAST line that looks like JSON.
    $jsonLine = $null
    foreach ($ln in ($txt -split "`r?`n")) {
        $t = $ln.Trim()
        if ($t.StartsWith('{') -or $t.StartsWith('[')) { $jsonLine = $t }
    }
    if (-not $jsonLine) { throw "Veeam query returned no JSON. Output: $txt" }
    return ($jsonLine | ConvertFrom-Json)
}

function Get-VeeamLiveState {
    $code = @'
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  $jobs = @()
  foreach ($j in @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)) {
    $jobs += [ordered]@{ name=[string]$j.Name; type=[string]$j.JobType; enabled=[bool]$j.IsScheduleEnabled }
  }
  if (Get-Command Get-VBRComputerBackupJob -ErrorAction SilentlyContinue) {
    foreach ($j in @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)) {
      $jobs += [ordered]@{ name=[string]$j.Name; type='AgentPolicy'; enabled=[bool]$j.JobEnabled }
    }
  }
  $repos = @()
  foreach ($r in @(Get-VBRBackupRepository -ErrorAction Stop)) {
    $repos += [ordered]@{ name=[string]$r.Name; type=[string]$r.Type; path=[string]$r.Path }
  }
  $objRepos = @()
  if (Get-Command Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue) {
    foreach ($o in @(Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue)) {
      $t = 'Unknown'
      foreach ($p in @('Type','ObjectStorageType')) { if ($o.PSObject.Properties.Name -contains $p) { $t = [string]$o.$p; break } }
      $objRepos += [ordered]@{ name=[string]$o.Name; type=$t }
    }
  }
  $s3 = 0
  if (Get-Command Get-VBRAmazonAccount -ErrorAction SilentlyContinue) {
    $s3 = @(Get-VBRAmazonAccount -ErrorAction SilentlyContinue).Count
  }
  $sessions = @()
  try {
    $sessions = @(Get-VBRBackupSession -ErrorAction SilentlyContinue |
      Sort-Object CreationTime -Descending | Select-Object -First $TrimCount |
      ForEach-Object { [ordered]@{ jobName=[string]$_.JobName; result=[string]$_.Result; createdUtc=$_.CreationTime.ToUniversalTime().ToString('o') } })
  } catch { }
  $copy = @()
  $seen = @{}
  if (Get-Command Get-VBRBackupCopyJob -ErrorAction SilentlyContinue) {
    foreach ($j in @(Get-VBRBackupCopyJob -ErrorAction SilentlyContinue)) {
      $n = [string]$j.Name
      $en = $true
      foreach ($p in @('JobEnabled','Enabled','IsEnabled')) { if ($j.PSObject.Properties.Name -contains $p) { $en = [bool]$j.$p; break } }
      $l = $sessions | Where-Object { $_.jobName -eq $n } | Select-Object -First 1
      $copy += [ordered]@{ name=$n; enabled=$en; lastResult=$(if($l){$l.result}else{'None'}); lastUtc=$(if($l){$l.createdUtc}else{$null}) }
      $seen[$n] = $true
    }
  }
  foreach ($j in @(Get-VBRJob -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object { [string]$_.JobType -match 'Copy|Sync' })) {
    $n = [string]$j.Name
    if ($seen.ContainsKey($n)) { continue }
    $l = $sessions | Where-Object { $_.jobName -eq $n } | Select-Object -First 1
    $copy += [ordered]@{ name=$n; enabled=[bool]$j.IsScheduleEnabled; lastResult=$(if($l){$l.result}else{'None'}); lastUtc=$(if($l){$l.createdUtc}else{$null}) }
  }
  $backups = @()
  foreach ($b in @(Get-VBRBackup -ErrorAction Stop)) {
    $pts = @(Get-VBRRestorePoint -Backup $b -ErrorAction SilentlyContinue)
    $nw = ($pts | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime
    $backups += [ordered]@{ name=[string]$b.Name; pointCount=$pts.Count; newestUtc=$(if($nw){$nw.ToUniversalTime().ToString('o')}else{$null}) }
  }
  @{ ok=$true; jobs=$jobs; repos=$repos; objectRepos=$objRepos; s3CredCount=$s3;
     copyJobs=$copy; backups=$backups; sessions=$sessions } | ConvertTo-Json -Depth 6 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message } | ConvertTo-Json -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix "`$TrimCount = $SessionTrimCount"
}

function Get-VeeamPreflightState {
    $code = @'
$r = @{ ok=$true }
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  $working = @()
  try {
    $working += @(Get-VBRBackupSession -ErrorAction Stop | Where-Object { $_.State -eq 'Working' })
    if (Get-Command Get-VBRRestoreSession -ErrorAction SilentlyContinue) {
      $working += @(Get-VBRRestoreSession -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Working' })
    }
    $r.workingSessions = $working.Count
    $r.workingJobNames = @($working | ForEach-Object { [string]$_.JobName } | Select-Object -Unique) -join ', '
  } catch { $r.workingSessionsError = [string]$_.Exception.Message }
  try {
    $b = @(Get-VBRBackup -ErrorAction Stop)
    $r.backupCount = $b.Count
    $r.legacyChain = @($b | Where-Object { $_.PSObject.Properties.Name -contains 'IsMetaExist' -and $_.IsMetaExist -eq $true }).Count
  } catch { $r.legacyChainError = [string]$_.Exception.Message }
  try {
    $r.legacyCopyJobs = @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object { [string]$_.JobType -eq 'BackupSync' }).Count
  } catch { $r.legacyCopyJobsError = [string]$_.Exception.Message }
  try {
    $r.hardenedRepos = @(Get-VBRBackupRepository -ErrorAction Stop | Where-Object { [string]$_.Type -match 'Hardened' }).Count
  } catch { $r.hardenedReposError = [string]$_.Exception.Message }
  try {
    $r.repoPaths = @(Get-VBRBackupRepository -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Path } | Where-Object { $_ })
  } catch { $r.repoPaths = @() }
  $r.objectRepoCount = 0
  try {
    if (Get-Command Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue) {
      $r.objectRepoCount = @(Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue).Count
    }
  } catch { }
  $r.copyJobCount = 0
  try {
    $seen = @{}
    if (Get-Command Get-VBRBackupCopyJob -ErrorAction SilentlyContinue) {
      foreach ($j in @(Get-VBRBackupCopyJob -ErrorAction SilentlyContinue)) { $seen[[string]$j.Name] = $true }
    }
    foreach ($j in @(Get-VBRJob -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object { [string]$_.JobType -match 'Copy|Sync' })) { $seen[[string]$j.Name] = $true }
    $r.copyJobCount = $seen.Keys.Count
  } catch { }
}
catch { $r = @{ ok=$false; error=[string]$_.Exception.Message } }
$r | ConvertTo-Json -Depth 4 -Compress
'@
    return Invoke-VeeamQuery -Script $code
}

function Invoke-AgentUpdateQuery {
    # THE COMPONENT UPGRADE THE CONSOLE ACTUALLY DOES.
    #
    # After the 2026-09-23 wave, 12 of 15 reported sites had the same note:
    # "components did not automatically update, updated components and retried
    # job, job started successfully". The script's existing check was not
    # wrong - Get-VBRPhysicalHost reported "Managed hosts: 1; out of date: 0"
    # and the hosts genuinely WERE current. The components that had not
    # updated were the AGENTS on the protected endpoints.
    #
    # <SERVER12> showed it plainly: four endpoints on 13.1.1.700, one on
    # 13.1.0.544, and two reporting RebootRequired=True. The job failures were
    # on the stale ones.
    #
    # Install-VBRDiscoveredComputerAgent - which this script already used - is
    # the DEPLOY path. The UPDATE path is a different pair:
    #   Get-VBRDiscoveredComputerUpdate  -Id / -AgentVersion
    #   Set-VBRDiscoveredComputerUpdate  -Update -DiscoveredComputer
    # An endpoint reporting RebootRequired cannot complete either until that
    # workstation reboots, so those are named rather than retried.
    $code = @'
$log = New-Object System.Collections.Generic.List[string]
$updated = @(); $pendingReboot = @(); $failed = @(); $current = 0
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  if (-not (Get-Command Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue)) {
    @{ ok=$true; skipped='Get-VBRDiscoveredComputer not available'; log=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }
  $dcs = @(Get-VBRDiscoveredComputer -ErrorAction Stop)
  if ($dcs.Count -eq 0) {
    @{ ok=$true; log=@('No agent-managed computers registered.'); updated=@(); pendingReboot=@(); failed=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }

  # The newest agent version present is the de facto target for this site.
  $versions = @($dcs | ForEach-Object { [string]$_.AgentVersion } | Where-Object { $_ } | Sort-Object -Unique)
  $newest = $null
  foreach ($v in $versions) { $pv=$null; if ([version]::TryParse($v,[ref]$pv)) { if (-not $newest -or $pv -gt $newest) { $newest = $pv } } }
  $log.Add("Agent inventory: $($dcs.Count) endpoint(s); versions present: $($versions -join ', ')$(if ($newest) { "; newest = $newest" })")

  $haveUpd = (Get-Command Get-VBRDiscoveredComputerUpdate -ErrorAction SilentlyContinue) -and
             (Get-Command Set-VBRDiscoveredComputerUpdate -ErrorAction SilentlyContinue)
  $haveDeploy = [bool](Get-Command Install-VBRDiscoveredComputerAgent -ErrorAction SilentlyContinue)
  if (-not $haveUpd -and -not $haveDeploy) {
    @{ ok=$true; skipped='No agent update or deploy cmdlet available on this build'; log=@($log) } | ConvertTo-Json -Depth 4 -Compress
    return
  }

  foreach ($dc in $dcs) {
    $name = [string]$dc.Name
    $ver  = [string]$dc.AgentVersion
    if ([string]$dc.State -ne 'Online') { $log.Add("  ${name} (${ver}): $([string]$dc.State) - skipped"); continue }

    # VEEAM'S OWN VERDICT FIRST.
    # The old test compared each agent against the NEWEST AGENT ALREADY AT THIS
    # SITE. A site with one endpoint therefore compared that agent to itself
    # and called it current, and a site whose agents were ALL old called every
    # one of them current. Nothing was ever upgraded. Seen as an hourly
    # "Backup agent server01 requires upgrade" / "Server server01 has an
    # outdated Data Mover service version" on a single-endpoint agent job
    # (servers01, 0 of 1 hosts processed) on 2026-09-29.
    # AgentStatus is Veeam's assessment against what THIS backup server can
    # deliver - it read UpgradeAvailable on <CLIENT> (<SERVER21>). Use it
    # whenever the property exists; fall back to the version comparison only
    # on builds that do not expose it.
    $status = $null
    if ($dc.PSObject.Properties.Name -contains 'AgentStatus') { $status = [string]$dc.AgentStatus }
    $isCurrent = $false
    if ($status) {
      $isCurrent = ($status -ne 'UpgradeAvailable')
    } else {
      $pv = $null
      if ($newest -and [version]::TryParse($ver,[ref]$pv)) { $isCurrent = ($pv -ge $newest) }
    }
    if ($isCurrent) { $current++; continue }
    $log.Add("  ${name} (${ver}): $(if ($status) { "AgentStatus=$status" } else { 'older than the newest agent at this site' }) - upgrading.")

    if ($dc.PSObject.Properties.Name -contains 'RebootRequired' -and $dc.RebootRequired) {
      $log.Add("  ${name} (${ver}): RebootRequired=True - the agent update CANNOT complete until that endpoint reboots. Not attempted.")
      $pendingReboot += "$name (agent $ver, endpoint awaiting reboot)"
      continue
    }

    $done = $false
    if ($haveUpd) {
      try {
        $upd = $null
        try { $upd = Get-VBRDiscoveredComputerUpdate -Id $dc.Id -ErrorAction Stop } catch { }
        if ($upd) {
          Set-VBRDiscoveredComputerUpdate -Update $upd -DiscoveredComputer $dc -ErrorAction Stop | Out-Null
          $log.Add("  ${name}: agent update from $ver requested (update path).")
          $updated += "$name (was $ver)"
          $done = $true
        } else {
          $log.Add("  ${name}: no update object returned for this computer - using the deploy path.")
        }
      } catch {
        $log.Add("  ${name}: update path failed - $($_.Exception.Message) - using the deploy path.")
      }
    }

    # THE DEPLOY PATH IS THE ONE PROVEN TO WORK.
    # Install-VBRDiscoveredComputerAgent dispatches a real "Operation
    # UpgradeAgent" deployment and runs the agent MSI on the endpoint - its
    # own deploy log on <SERVER21> showed exactly that. It returns a
    # session rather than throwing when the MSI fails, so the Result is read.
    # The old fallback here applied the FIRST update object found for ANY
    # computer to this one; it is gone.
    if (-not $done -and $haveDeploy) {
      try {
        $sess = Install-VBRDiscoveredComputerAgent -DiscoveredComputer $dc -ErrorAction Stop
        $res = $null
        try { $res = [string](@($sess) | Select-Object -Last 1).Result } catch { }
        if ($res -eq 'Failed') {
          $log.Add("  ${name}: agent upgrade from $ver ran and FAILED. On every endpoint so far this has been a pending Windows reboot blocking the MSI (Error 1714). Run 'Veeam Agent Registration Repair' in repair mode on ${name}, then re-run this script.")
          $failed += "$name (agent upgrade ran and failed - endpoint likely needs a reboot)"
        } else {
          $log.Add("  ${name}: agent upgrade from $ver dispatched (deploy path)$(if ($res) { ", result $res" }).")
          $updated += "$name (was $ver)"
        }
      } catch {
        $log.Add("  ${name} (${ver}): agent upgrade failed - $($_.Exception.Message)")
        $failed += "$name ($($_.Exception.Message))"
      }
    } elseif (-not $done) {
      $log.Add("  ${name} (${ver}): needs an upgrade but no deploy cmdlet exists on this build.")
      $failed += "$name (no deploy cmdlet)"
    }
  }
  $log.Add("Agents already current: $current of $($dcs.Count).")
  @{ ok=$true; log=@($log); updated=@($updated); pendingReboot=@($pendingReboot); failed=@($failed) } | ConvertTo-Json -Depth 4 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; log=@($log); updated=@($updated); pendingReboot=@($pendingReboot); failed=@($failed) } | ConvertTo-Json -Depth 4 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code
}

function Invoke-AgentUpdate {
    Write-Log '--- Agent (endpoint component) update ---'
    $r = $null
    try { $r = Invoke-AgentUpdateQuery } catch { Write-Log "Agent update query failed: $($_.Exception.Message)" 'WARN'; return }
    if ($null -eq $r) { return }
    foreach ($l in @($r.log)) { if ($l) { Write-Log $l } }
    if ($r.skipped) { Write-Log "Agent update skipped: $($r.skipped)" 'WARN'; return }
    if (-not $r.ok) { Write-Log "Agent update error: $($r.error)" 'WARN'; return }
    if (@($r.updated).Count -gt 0) {
        Write-Log ("AGENT UPDATE - requested on {0} endpoint(s): {1}" -f @($r.updated).Count, (@($r.updated) -join '; ')) 'WARN'
    }
    if (@($r.pendingReboot).Count -gt 0) {
        Write-Log ("AGENT UPDATE BLOCKED - {0} endpoint(s) need a WORKSTATION REBOOT before their agent can update. Backup jobs for these machines may fail until that happens: {1}" -f `
            @($r.pendingReboot).Count, (@($r.pendingReboot) -join '; ')) 'ERROR'
    }
    if (@($r.failed).Count -gt 0) {
        Write-Log ("AGENT UPDATE FAILED on {0}: {1}" -f @($r.failed).Count, (@($r.failed) -join '; ')) 'ERROR'
    }
}

function Invoke-ComponentUpgrade {
    # Get-VBRPhysicalHost exposes IsUpToDate; Update-VBRServerComponent takes
    # -Component <VBRPhysicalHost[]>. On <SERVER56> and <SERVER57> every host was
    # already IsUpToDate=True after the v13 install with VBR_AUTO_UPGRADE=0, so
    # this is usually a check, not work.
    # NOTE: there is NO cmdlet surface for the VSPC / Service Provider Console
    # dependency prompt. That remains a console action.
    $code = @'
$log = New-Object System.Collections.Generic.List[string]
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  if (-not (Get-Command Get-VBRPhysicalHost -ErrorAction SilentlyContinue)) {
    @{ ok=$true; skipped='Get-VBRPhysicalHost not available on this build'; log=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }
  $vhosts = @(Get-VBRPhysicalHost -ErrorAction Stop)
  $stale = @($vhosts | Where-Object { $_.PSObject.Properties.Name -contains 'IsUpToDate' -and -not $_.IsUpToDate })
  $log.Add("Managed hosts: $($vhosts.Count); out of date: $($stale.Count).")
  if ($stale.Count -eq 0) {
    @{ ok=$true; upgraded=@(); log=@($log) } | ConvertTo-Json -Depth 4 -Compress
    return
  }
  foreach ($h in $stale) { $log.Add("  out of date: $([string]$h.Name)") }
  Update-VBRServerComponent -Component $stale -ErrorAction Stop | Out-Null
  $sw = [System.Diagnostics.Stopwatch]::StartNew(); $done = $false
  while ($sw.Elapsed.TotalSeconds -lt $CompWait) {
    Start-Sleep -Seconds 30
    $now = @(Get-VBRPhysicalHost -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'IsUpToDate' -and -not $_.IsUpToDate })
    if ($now.Count -eq 0) { $done = $true; break }
  }
  if ($done) { $log.Add("All managed host components are now up to date.") }
  else {
    $still = @(Get-VBRPhysicalHost -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'IsUpToDate' -and -not $_.IsUpToDate } | ForEach-Object { [string]$_.Name })
    $log.Add("Component upgrade did not finish within $CompWait s. Still out of date: $($still -join ', ')")
  }
  @{ ok=$true; upgraded=@($stale | ForEach-Object { [string]$_.Name }); completed=$done; log=@($log) } | ConvertTo-Json -Depth 4 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; log=@($log) } | ConvertTo-Json -Depth 4 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix "`$CompWait = $ComponentWaitSecs"
}

# =============================================================================
# JOB PAUSE / RESTORE
#
# WHY: NoActiveSessions was only a preflight GATE, checked at minute zero.
# The script then spent 20-40 minutes downloading, hashing and extracting an
# 18 GB ISO before it tried to stop VeeamBackupSvc - by which time Veeam's own
# scheduler had fired an hourly job the gate never saw. That job holds the
# service, the stop times out at 600 s, and the script reboots having achieved
# nothing. 120 devices did exactly this in the 2026-09-22 wave.
#
# So: disable the job schedules, wait for anything already running to drain,
# THEN do the work, and restore.
#
# THE RESTORE IS THE DANGEROUS PART. A site whose jobs stay disabled because
# this script died is a worse outcome than a failed upgrade. Restore therefore
# happens in four places:
#   1. at script start, recovering from a run that died or rebooted
#   2. immediately before EVERY deliberate reboot
#   3. in the finally block
#   4. on the next scheduled run, from the on-disk state file
# =============================================================================

function Invoke-JobPauseQuery {
    # Disables every enabled job, records what was enabled, then waits for any
    # running session to drain.
    #
    # THE STATE FILE IS WRITTEN BY THIS QUERY, BEFORE THE FIRST DISABLE. v4.7
    # wrote it afterwards from the return value - so when the helper threw on
    # the way back, nothing had been recorded and the restore had nothing to
    # work from. Three sites were left with backups disabled.
    #
    # v13 DEPRECATED Disable-VBRJob for computer-backup and backup-copy jobs.
    # It still works but emits WARNING text, which is what contaminated the
    # JSON stream. Use the type-specific cmdlet where one exists.
    param([int]$DrainSeconds, [int]$PollSeconds, [string]$StateFile)
    $prefix = @"
`$DrainSeconds = $DrainSeconds
`$PollSeconds = $PollSeconds
`$StateFile = '$($StateFile -replace "'","''")'
"@
    $code = @'
$log = New-Object System.Collections.Generic.List[string]
$state = @(); $failed = @()

function Set-JobEnabled {
    # Returns the cmdlet that worked, or throws. Type-specific first.
    param($Job, [bool]$Enable)
    $verb = if ($Enable) { 'Enable' } else { 'Disable' }
    $t    = [string]$Job.JobType
    $name = [string]$Job.Name
    $tries = @()
    if ($t -match 'Copy|Sync')      { $tries += @{ get='Get-VBRBackupCopyJob';    set="$verb-VBRBackupCopyJob" } }
    if ($t -match 'EpAgent|Agent')  { $tries += @{ get='Get-VBRComputerBackupJob'; set="$verb-VBRComputerBackupJob" } }
    $tries += @{ get=$null; set="$verb-VBRJob" }

    $lastErr = $null
    foreach ($try in $tries) {
        if (-not (Get-Command $try.set -ErrorAction SilentlyContinue)) { continue }
        try {
            $target = $Job
            if ($try.get -and (Get-Command $try.get -ErrorAction SilentlyContinue)) {
                $t2 = @(& $try.get -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                        Where-Object { [string]$_.Name -eq $name }) | Select-Object -First 1
                if ($t2) { $target = $t2 }
            }
            & $try.set -Job $target -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            return $try.set
        } catch { $lastErr = $_.Exception.Message }
    }
    throw $(if ($lastErr) { $lastErr } else { "no usable $verb cmdlet for job type '$t'" })
}

try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }

  $jobs = @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)
  foreach ($j in $jobs) {
    $en = $false
    foreach ($p in @('IsScheduleEnabled','JobEnabled','Enabled','IsEnabled')) {
      if ($j.PSObject.Properties.Name -contains $p) { $en = [bool]$j.$p; break }
    }
    $state += [ordered]@{ name = [string]$j.Name; wasEnabled = $en; jobType = [string]$j.JobType }
  }

  # DO NOT RECORD AN ALL-DISABLED BASELINE. If nothing is enabled there is
  # nothing to pause and nothing to restore - and writing the file anyway
  # poisons every later restore, which would faithfully put the jobs back to
  # disabled. v4.18 did this on <SERVER49> and <SERVER31> and made two already
  # dark sites harder to recover.
  $anyEnabled = @($state | Where-Object { $_.wasEnabled }).Count
  if ($anyEnabled -eq 0) {
    $log.Add("No jobs are enabled on this device - nothing to pause. NOT writing a state file; an all-disabled baseline would poison any later restore.")
    @{ ok=$true; drained=$true; state=@($state); failed=@(); log=@($log); nothingEnabled=$true } | ConvertTo-Json -Depth 5 -Compress
    return
  }

  # RECORD BEFORE TOUCHING ANYTHING. If this write fails we do not disable.
  try {
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
  } catch {
    @{ ok=$false; error="could not write the job state file '$StateFile': $($_.Exception.Message) - refusing to disable anything"; state=@(); failed=@(); log=@() } | ConvertTo-Json -Depth 5 -Compress
    return
  }

  foreach ($j in $jobs) {
    $n = [string]$j.Name
    $rec = $state | Where-Object { $_.name -eq $n } | Select-Object -First 1
    if (-not $rec.wasEnabled) { continue }
    try {
      $used = Set-JobEnabled -Job $j -Enable $false
      $log.Add("  paused '$n' [$([string]$j.JobType)] via $used")
    } catch {
      $failed += "$n ($($_.Exception.Message))"
      $log.Add("  COULD NOT PAUSE '$n' [$([string]$j.JobType)]: $($_.Exception.Message)")
    }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew(); $drained = $false; $last = ''
  while ($sw.Elapsed.TotalSeconds -lt $DrainSeconds) {
    $working = @()
    try {
      $working += @(Get-VBRBackupSession -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Working' })
      if (Get-Command Get-VBRRestoreSession -ErrorAction SilentlyContinue) {
        $working += @(Get-VBRRestoreSession -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Working' })
      }
    } catch { }
    if ($working.Count -eq 0) { $drained = $true; break }
    $names = (@($working | ForEach-Object { [string]$_.JobName } | Select-Object -Unique) -join ', ')
    if ($names -ne $last) { $log.Add("  waiting on running job(s): $names"); $last = $names }
    Start-Sleep -Seconds $PollSeconds
  }
  if (-not $drained) {
    $still = @()
    try { $still = @(Get-VBRBackupSession -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Working' } | ForEach-Object { [string]$_.JobName }) } catch { }
    $log.Add("  still running after $DrainSeconds s: $($still -join ', ')")
  }

  @{ ok=$true; drained=$drained; state=@($state); failed=@($failed); log=@($log) } | ConvertTo-Json -Depth 5 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; state=@($state); failed=@($failed); log=@($log) } | ConvertTo-Json -Depth 5 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix $prefix
}

function Invoke-JobRestoreQuery {
    param([string[]]$Names)
    $lit = if ($Names.Count -gt 0) {
        "@(" + (($Names | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")"
    } else { '@()' }
    $code = @'
$restored = @(); $failed = @()

function Set-JobEnabled {
    param($Job, [bool]$Enable)
    $verb = if ($Enable) { 'Enable' } else { 'Disable' }
    $t    = [string]$Job.JobType
    $name = [string]$Job.Name
    $tries = @()
    if ($t -match 'Copy|Sync')     { $tries += @{ get='Get-VBRBackupCopyJob';     set="$verb-VBRBackupCopyJob" } }
    if ($t -match 'EpAgent|Agent') { $tries += @{ get='Get-VBRComputerBackupJob'; set="$verb-VBRComputerBackupJob" } }
    $tries += @{ get=$null; set="$verb-VBRJob" }
    $lastErr = $null
    foreach ($try in $tries) {
        if (-not (Get-Command $try.set -ErrorAction SilentlyContinue)) { continue }
        try {
            $target = $Job
            if ($try.get -and (Get-Command $try.get -ErrorAction SilentlyContinue)) {
                $t2 = @(& $try.get -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
                        Where-Object { [string]$_.Name -eq $name }) | Select-Object -First 1
                if ($t2) { $target = $t2 }
            }
            & $try.set -Job $target -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            return $try.set
        } catch { $lastErr = $_.Exception.Message }
    }
    throw $(if ($lastErr) { $lastErr } else { "no usable $verb cmdlet for job type '$t'" })
}

try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  $all = @(Get-VBRJob -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)
  foreach ($n in $Names) {
    $j = $all | Where-Object { [string]$_.Name -eq $n } | Select-Object -First 1
    if (-not $j) { $failed += "$n (job no longer exists)"; continue }
    try { [void](Set-JobEnabled -Job $j -Enable $true); $restored += $n }
    catch { $failed += "$n ($($_.Exception.Message))" }
  }
  @{ ok=$true; restored=@($restored); failed=@($failed) } | ConvertTo-Json -Depth 4 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; restored=@($restored); failed=@($failed) } | ConvertTo-Json -Depth 4 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix "`$Names = $lit"
}

function Suspend-VeeamJobs {
    # Returns $true if the install window is safe to proceed into.
    # EVERY failure path below restores first. v4.7 threw before the restore
    # and left three sites with their backups disabled while logging
    # "Nothing on this box was changed" - which was false.
    if (-not $PauseJobs) { Write-Log 'Job pausing disabled (pauseJobsDuringUpgrade=0).' 'WARN'; return $true }
    Write-Log "Pausing job schedules and waiting up to $([int]($SessionDrainWaitSecs/60)) min for running jobs to finish ..."

    $r = $null
    try {
        $r = Invoke-JobPauseQuery -DrainSeconds $SessionDrainWaitSecs -PollSeconds $SessionPollSecs -StateFile $JobStateFile
    } catch {
        Write-Log "Job pause threw: $($_.Exception.Message)" 'ERROR'
        Write-Log 'Attempting restore anyway - the query writes its state file BEFORE disabling, so anything it paused is recoverable.' 'WARN'
        Restore-PausedJobsFromMemory
        Restore-VeeamJobs
        return $false
    }
    if ($null -eq $r) {
        Write-Log 'Job pause returned nothing. Attempting restore.' 'ERROR'
        Restore-VeeamJobs
        return $false
    }
    foreach ($l in @($r.log)) { if ($l) { Write-Log $l } }
    if (-not $r.ok) {
        Write-Log "Job pause error: $($r.error)" 'ERROR'
        Restore-VeeamJobs
        return $false
    }
    if (@($r.failed).Count -gt 0) {
        Write-Log ("Could not pause {0} job(s): {1}" -f @($r.failed).Count, (@($r.failed) -join '; ')) 'WARN'
    }
    if (-not $r.drained) {
        Write-Log 'A job is still running after the wait. Restoring schedules and halting - the install would race it.' 'ERROR'
        Restore-VeeamJobs
        return $false
    }
    $script:PausedJobNames = @($r.state | Where-Object { $_.wasEnabled } | ForEach-Object { [string]$_.name })
    Write-Log ("Jobs paused ({0} were enabled) and no sessions running. Safe to install. Held in memory for restore: {1}" -f `
        $script:PausedJobNames.Count, ($script:PausedJobNames -join ', '))
    Write-Log "Original job states recorded at $JobStateFile - restored automatically at the start of any later run if this one dies."
    return $true
}

function Repair-AllJobsDisabled {
    # SELF-HEAL A SITE THIS SCRIPT LEFT DARK.
    #
    # v4.7's job pause disabled jobs and failed to re-enable them on five
    # devices. The restore path cannot recover them: it reads jobs-paused.json,
    # and on the NEXT run that file was rewritten with wasEnabled=false for
    # every job - a truthful record of what it found, and useless for recovery.
    # <SERVER49>, <SERVER50> and <SERVER31> have been backing up nothing since.
    #
    # The risk of just re-enabling things is obvious: a tech may have disabled
    # a job on purpose. So this fires ONLY when ALL of the following hold:
    #   - EVERY job on the box is disabled. A site with zero enabled jobs is
    #     broken, never a deliberate state.
    #   - this script has touched the box before (a jobs-paused.json exists,
    #     or one was written previously), so it is plausibly our doing.
    #   - it has not already self-healed. One attempt, recorded, never a loop
    #     that fights somebody switching a job off.
    # The marker stops this looping against a tech who switches a job off, but
    # it must NOT permanently blind the exit guard: if the marker says we
    # healed and the jobs are disabled AGAIN with recent sessions, that is a
    # new failure, not the old one. Only skip when the marker was written for
    # a device we deliberately left alone.
    if (Test-Path -LiteralPath $SelfHealMarkerFile) {
        $prev = $null
        try { $prev = Get-Content -LiteralPath $SelfHealMarkerFile -Raw | ConvertFrom-Json } catch { }
        if ($prev -and $prev.note -match 'left alone') {
            return   # previously judged deliberate - do not revisit
        }
        Write-Log 'This device was self-healed before and its jobs are disabled again - re-checking rather than assuming.' 'WARN'
        Remove-Item -LiteralPath $SelfHealMarkerFile -Force -ErrorAction SilentlyContinue
    }
    # v4.18 required a jobs-paused.json to exist before it would act. That was
    # exactly backwards: <SERVER49> and <SERVER31> have had every job disabled
    # since v4.7 and their state file was long gone, so the check returned
    # immediately and the sites stayed dark. The signal is the job state
    # itself, not the presence of a file.

    $r = $null
    try { $r = Invoke-VeeamQuery -Prefix "`$RecentDays = $SelfHealRecentDays" -Script @'
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  # ASK THE JOB WHEN IT LAST RAN. Do not try to reverse-engineer it from
  # session names: sessions on these devices are recorded as
  # "S3 Copy Job\HyperV Backup - <SERVER-DC>" - the copy job's name, a
  # backslash, then the object - so a job called "Server01" never appears
  # under its own name. v4.20 matched on names, found nothing, and declared
  # jobs that were running daily to be 30 days idle. That is why three sites
  # stayed dark.
  $cut = (Get-Date).AddDays(-$RecentDays)
  $jobs = @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)
  $out = @()
  foreach ($j in $jobs) {
    $en = $false
    foreach ($p in @('IsScheduleEnabled','JobEnabled','Enabled','IsEnabled')) {
      if ($j.PSObject.Properties.Name -contains $p) { $en = [bool]$j.$p; break }
    }
    $nm = [string]$j.Name
    $last = $null
    # Several sources, first that answers wins - these differ by job type.
    try { if ($j.PSObject.Methods.Name -contains 'FindLastSession') {
            $ls = $j.FindLastSession(); if ($ls) { $last = $ls.CreationTime } } } catch { }
    if (-not $last) { foreach ($p in @('LatestRunLocal','LastRun','LatestRun')) {
        try { if ($j.PSObject.Properties.Name -contains $p -and $j.$p) { $last = [datetime]$j.$p; break } } catch { } } }
    if (-not $last) { try {
        $so = Get-VBRJobScheduleOptions -Job $j -ErrorAction SilentlyContinue
        if ($so -and $so.LatestRunLocal) { $last = [datetime]$so.LatestRunLocal }
      } catch { } }
    # Unknown is NOT the same as never. If we cannot tell, assume it is live -
    # the cost of wrongly re-enabling is far lower than leaving a site dark.
    $recent = $true
    if ($last) { $recent = ($last -gt $cut) }
    $out += [ordered]@{ name=$nm; enabled=$en; jobType=[string]$j.JobType
                        ranRecently=$recent
                        lastRunUtc=$(if ($last) { $last.ToUniversalTime().ToString('o') } else { $null })
                        lastRunKnown=[bool]$last }
  }
  @{ ok=$true; jobs=@($out); recentDays=$RecentDays } | ConvertTo-Json -Depth 4 -Compress
}
catch { @{ ok=$false; error=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@ } catch {
        Write-Log "Could not read job state for the self-heal check: $($_.Exception.Message)" 'WARN'
        return
    }
    if ($null -eq $r -or -not $r.ok) { return }
    $all = @($r.jobs)
    if ($all.Count -eq 0) { return }
    $enabled = @($all | Where-Object { $_.enabled })
    if ($enabled.Count -gt 0) { return }   # something is live - leave it alone

    # ONLY RE-ENABLE JOBS THAT WERE ACTUALLY IN USE.
    # A disabled job with no session in the last $SelfHealRecentDays days was
    # almost certainly switched off on purpose - a decommissioned client, a
    # migration, a BDR being retired. Turning those back on would be the script
    # overriding a deliberate decision. Only jobs that ran recently and are now
    # disabled fit the profile of something this script paused and failed to
    # restore.
    $revive = @($all | Where-Object { $_.ranRecently })
    $leave  = @($all | Where-Object { -not $_.ranRecently })

    foreach ($j in $leave) {
        Write-Log ("SELF-HEAL: leaving '{0}' [{1}] disabled - no session in the last {2} days (last run: {3}). Assuming this was deliberate." -f `
            $j.name, $j.jobType, $SelfHealRecentDays, $(if ($j.lastRunUtc) { $j.lastRunUtc } else { 'unknown' })) 'WARN'
    }
    if ($revive.Count -eq 0) {
        Write-Log ("SELF-HEAL: all {0} job(s) are disabled, but none has run in the last {1} days - nothing here looks like an accidental pause. Leaving the device alone and continuing with the upgrade." -f `
            $all.Count, $SelfHealRecentDays) 'WARN'
        try {
            [pscustomobject]@{ healedUtc=(Get-Date).ToUniversalTime().ToString('o'); restored=@(); failed=@()
                               note="all jobs disabled but none ran within $SelfHealRecentDays days - left alone" } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SelfHealMarkerFile -Encoding UTF8 -Force
        } catch { }
        return
    }

    Write-Log ("SELF-HEAL: all {0} job(s) on this device are disabled, and {1} of them ran within the last {2} days - that is the signature of a pause this script failed to restore. Re-enabling: {3}" -f `
        $all.Count, $revive.Count, $SelfHealRecentDays, ((@($revive | ForEach-Object { [string]$_.name })) -join ', ')) 'ERROR'

    $fix = $null
    try { $fix = Invoke-JobRestoreQuery -Names @($revive | ForEach-Object { [string]$_.name }) } catch {
        Write-Log "SELF-HEAL FAILED: $($_.Exception.Message). JOBS ARE STILL DISABLED - this device needs a person." 'ERROR'
        return
    }
    if ($null -eq $fix -or -not $fix.ok) {
        Write-Log "SELF-HEAL FAILED: $(if($fix){$fix.error}else{'no output'}). JOBS ARE STILL DISABLED - this device needs a person." 'ERROR'
        return
    }
    if (@($fix.failed).Count -gt 0) {
        Write-Log ("SELF-HEAL: could not re-enable {0}: {1}. This device needs a person." -f @($fix.failed).Count, (@($fix.failed) -join '; ')) 'ERROR'
    }
    if (@($fix.restored).Count -gt 0) {
        Write-Log ("SELF-HEAL: re-enabled {0} job(s): {1}. This site is backing up again." -f @($fix.restored).Count, (@($fix.restored) -join ', ')) 'WARN'
    }
    try {
        [pscustomobject]@{
            healedUtc = (Get-Date).ToUniversalTime().ToString('o')
            restored  = @($fix.restored)
            failed    = @($fix.failed)
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SelfHealMarkerFile -Encoding UTF8 -Force
    } catch { }
    Remove-Item -LiteralPath $JobStateFile -Force -ErrorAction SilentlyContinue
}

function Restore-PausedJobsFromMemory {
    # FIRST LINE OF RESTORE, AND THE ONE THAT CANNOT BE LOST.
    # Every incident in this script's history came from the restore depending on
    # jobs-paused.json. This path uses the in-memory list instead, so a missing,
    # stale or poisoned file cannot leave a site disabled.
    if (@($script:PausedJobNames).Count -eq 0) { return }
    Write-Log ("Re-enabling {0} job(s) paused by this run (from memory): {1}" -f `
        @($script:PausedJobNames).Count, (@($script:PausedJobNames) -join ', ')) 'WARN'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $r = $null
        try { $r = Invoke-JobRestoreQuery -Names $script:PausedJobNames } catch {
            Write-Log ("  attempt {0} of 3 failed: {1}" -f $attempt, $_.Exception.Message) 'WARN'
            if ($attempt -lt 3) { Start-Sleep -Seconds 20 }
            continue
        }
        if ($r -and $r.ok -and @($r.failed).Count -eq 0) {
            Write-Log ("Re-enabled {0} job(s): {1}" -f @($r.restored).Count, (@($r.restored) -join ', '))
            $script:PausedJobNames = @()
            Remove-Item -LiteralPath $JobStateFile -Force -ErrorAction SilentlyContinue
            return
        }
        if ($r -and @($r.failed).Count -gt 0) {
            Write-Log ("  attempt {0} of 3 - could not re-enable: {1}" -f $attempt, (@($r.failed) -join '; ')) 'WARN'
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 20 }
    }
    Write-Log 'COULD NOT RE-ENABLE FROM MEMORY after 3 attempts. The state file is retained and the exit guard will try again.' 'ERROR'
}

function Restore-VeeamJobs {
    # Idempotent and safe to call repeatedly. Called at script start, before
    # every deliberate reboot, and in finally.
    if (-not (Test-Path -LiteralPath $JobStateFile)) { return }
    $saved = $null
    try { $saved = Get-Content -LiteralPath $JobStateFile -Raw | ConvertFrom-Json }
    catch {
        Write-Log "JOB STATE FILE $JobStateFile IS UNREADABLE ($($_.Exception.Message)). Jobs may still be paused on this device - CHECK BY HAND." 'ERROR'
        return
    }
    $names = @($saved | Where-Object { $_.wasEnabled } | ForEach-Object { [string]$_.name })
    if ($names.Count -eq 0) { Remove-Item -LiteralPath $JobStateFile -Force -ErrorAction SilentlyContinue; return }

    Write-Log ("Restoring {0} paused job schedule(s) ..." -f $names.Count) 'WARN'
    # Retry: <SERVER51> paused successfully, FATAL'd on a stale LAPS
    # credential, and then could not re-enable because the Veeam session had
    # gone. One transient failure should not leave a site unprotected.
    $r = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $r = Invoke-JobRestoreQuery -Names $names; break }
        catch {
            Write-Log ("Job restore attempt {0} of 3 failed: {1}" -f $attempt, $_.Exception.Message) 'WARN'
            if ($attempt -lt 3) { Start-Sleep -Seconds 20 }
        }
    }
    if ($null -eq $r) {
        Write-Log "JOB RESTORE FAILED after 3 attempts. State file RETAINED at $JobStateFile - the next run will retry. JOBS ARE STILL PAUSED ON THIS DEVICE." 'ERROR'
        return
    }
    if ($null -eq $r -or -not $r.ok) {
        Write-Log "JOB RESTORE ERROR: $(if($r){$r.error}else{'no output'}). State file RETAINED; next run retries. JOBS MAY STILL BE PAUSED." 'ERROR'
        return
    }
    if (@($r.failed).Count -gt 0) {
        Write-Log ("COULD NOT RE-ENABLE {0} job(s): {1}. State file RETAINED; next run retries." -f @($r.failed).Count, (@($r.failed) -join '; ')) 'ERROR'
        return
    }
    Write-Log ("Re-enabled {0} job(s): {1}" -f @($r.restored).Count, (@($r.restored) -join ', '))
    Remove-Item -LiteralPath $JobStateFile -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# AGENT BLOCKER REMEDIATION
# =============================================================================

function Invoke-AgentRemediationQuery {
    param([string[]]$TargetNames = @(), [int]$StaleDays = 180, [int]$RestorePointDays = 60, [bool]$ReportOnly = $false)

    $namesLiteral = if ($TargetNames.Count -gt 0) {
        "@(" + (($TargetNames | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")"
    } else { '@()' }

    $prefix = @"
`$Targets = $namesLiteral
`$StaleDays = $StaleDays
`$RpDays = $RestorePointDays
`$ReportOnly = `$$($ReportOnly.ToString().ToLower())
`$UpgradeWait = $AgentUpgradeWaitSecs
"@

    $code = @'
$log = New-Object System.Collections.Generic.List[string]
$removed = @(); $upgraded = @(); $blocked = @()

function Get-AgentDeployFailure {
  # THE BDR ALREADY KNOWS WHY THE PUSH FAILED - READ IT.
  # Veeam writes a per-agent deployment log at
  #   C:\ProgramData\Veeam\Backup\Rescan\Rescan_of_<name>\Task.<name>-deploy.log
  # and it carries the exact MSI result. On <SERVER21> / <CLIENT> it read:
  #   Package installation result: is success: False (code: 1603)
  #   Error 1714.The older version of Veeam Agent for Microsoft Windows
  #   cannot be removed.
  # Without this the script reported only "agent upgrade did not complete",
  # which cost an hour of log archaeology for something already on disk.
  param([string]$AgentName)
  $out = @()
  try {
    $dir = Join-Path 'C:\ProgramData\Veeam\Backup\Rescan' ("Rescan_of_" + ($AgentName -replace '[\\/:*?"<>|]', '_'))
    if (-not (Test-Path -LiteralPath $dir)) { return $out }
    $f = Get-ChildItem -LiteralPath $dir -Filter '*-deploy.log' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return $out }
    $tail = @(Get-Content -LiteralPath $f.FullName -Tail 400 -ErrorAction SilentlyContinue)
    foreach ($pat in @('Package installation result', 'Error \d{3,5}\.', 'has not been updated', 'Unable to upgrade package')) {
      foreach ($m in @($tail | Select-String -Pattern $pat -ErrorAction SilentlyContinue)) {
        $t = ($m.Line -replace '^\[[^\]]+\]\s+<\d+>\s+\w+\s+\(\d+\)\s+', '').Trim()
        if ($t -and $out -notcontains $t) { $out += $t }
      }
    }
  } catch { }
  return @($out | Select-Object -First 4)
}

try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  if (-not (Get-Command Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue)) {
    @{ ok=$true; skipped='Get-VBRDiscoveredComputer not available'; log=@(); removed=@(); upgraded=@(); blocked=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }
  $all = @(Get-VBRDiscoveredComputer -ErrorAction Stop)
  if ($all.Count -eq 0) {
    @{ ok=$true; log=@('No agent-managed computers registered.'); removed=@(); upgraded=@(); blocked=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }

  if ($Targets.Count -gt 0) {
    $scope = @($all | Where-Object { $Targets -contains [string]$_.Name })
    $log.Add("Agent remediation scoped to $($scope.Count) machine(s) named by the installer: $($Targets -join ', ')")
  } else {
    $cut = (Get-Date).AddDays(-$StaleDays)
    $scope = @($all | Where-Object { [string]$_.State -eq 'Offline' -and $_.LastConnected -ne $null -and $_.LastConnected -lt $cut })
    if ($scope.Count -eq 0) {
      @{ ok=$true; log=@("Agent inventory: $($all.Count) machine(s), none offline beyond $StaleDays days."); removed=@(); upgraded=@(); blocked=@() } | ConvertTo-Json -Depth 4 -Compress
      return
    }
    $log.Add("Agent inventory: $($all.Count) machine(s); $($scope.Count) offline beyond $StaleDays days.")
  }

  foreach ($dc in $scope) {
    $name = [string]$dc.Name; $ver = [string]$dc.AgentVersion
    $st = [string]$dc.State; $last = $dc.LastConnected

    if ($st -eq 'Online') {
      if ($ReportOnly) { $log.Add("  $name ($ver, Online): would upgrade agent."); continue }
      # An endpoint with a pending reboot cannot finish an agent upgrade - the
      # attempt simply times out (<SERVER10>, <SERVER11>, <SERVER12> all burned 600 s
      # this way). Halt immediately and name the machine instead.
      if ($dc.PSObject.Properties.Name -contains 'RebootRequired' -and $dc.RebootRequired) {
        $log.Add("  $name ($ver, Online): RebootRequired=True on the endpoint - the agent upgrade cannot complete until that workstation reboots. NOT attempted.")
        $blocked += "$name (online, endpoint has a pending reboot - reboot that workstation, then re-run)"
        continue
      }
      try {
        $log.Add("  $name ($ver, Online): upgrading agent ...")
        Install-VBRDiscoveredComputerAgent -DiscoveredComputer $dc -ErrorAction Stop | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew(); $done = $false
        while ($sw.Elapsed.TotalSeconds -lt $UpgradeWait) {
          Start-Sleep -Seconds 30
          $now = Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $name } | Select-Object -First 1
          if ($now -and [string]$now.AgentVersion -ne $ver) {
            $log.Add("  $name agent $ver -> $([string]$now.AgentVersion)."); $upgraded += $name; $done = $true; break
          }
          if ($now -and $now.PSObject.Properties.Name -contains 'RebootRequired' -and $now.RebootRequired) {
            $log.Add("  $name now reports RebootRequired=True - the upgrade staged but needs that workstation rebooted to finish.")
            $blocked += "$name (online, agent upgrade staged; endpoint needs a reboot to complete)"
            $done = $true; break
          }
        }
        if (-not $done) {
          $post = Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $name } | Select-Object -First 1
          $ps = if ($post) { "State=$([string]$post.State) AgentVersion=$([string]$post.AgentVersion) AgentStatus=$([string]$post.AgentStatus) RebootRequired=$([string]$post.RebootRequired) OS=$([string]$post.OperatingSystem) $([string]$post.OperatingSystemVersion)" } else { 'device no longer enumerable' }
          $log.Add("  $name agent upgrade did not report a new version within $UpgradeWait s. Post-attempt: $ps")
          foreach ($d in @(Get-AgentDeployFailure -AgentName $name)) { $log.Add("    DEPLOY: $d") }
          $blocked += "$name (online, agent upgrade did not complete; $ps)"
        }
      } catch { $log.Add("  $name agent upgrade failed: $($_.Exception.Message)"); $blocked += "$name (online, agent upgrade failed: $($_.Exception.Message))" }
      continue
    }

    $age = $null
    if ($last) { $age = [int]((Get-Date) - $last).TotalDays }

    # AN INSTALLER-NAMED BLOCKER IS UPGRADED, NEVER REMOVED.
    # VbrDatabaseIssuesSetupReport.xml says "Please upgrade or remove the
    # following Veeam agents". An earlier version of this branch took the
    # second option. That was wrong and it was nearly costly: on
    # <SERVER34> the named machine was <HOSTNAME>.<CLIENT>.local, which turned out
    # to be ONLINE, connected 20 minutes earlier, with 400 restore points in
    # the Servers01 job. Removing its registration would have dropped a live
    # production server out of its backup job.
    #
    # "Not Online" does not mean decommissioned either - it can simply mean the
    # agent has not checked in. So this script never removes an
    # installer-named machine. It upgrades it where it can and HALTS, naming
    # the machine, where it cannot. A halted upgrade costs a run. A removed
    # registration costs a client their backups.
    if ($Targets.Count -gt 0) {
        # How much would be lost if someone did remove this - report it so the
        # halt message carries the weight of the decision.
        $rpCount = 0
        try {
            foreach ($b in @(Get-VBRBackup -ErrorAction SilentlyContinue)) {
                $rpCount += @(Get-VBRRestorePoint -Backup $b -ErrorAction SilentlyContinue |
                              Where-Object { [string]$_.Name -eq $name -or [string]$_.Name -eq ($name -split '\.')[0] }).Count
            }
        } catch { }

        if ($st -eq 'Online') {
            if ($ReportOnly) { $log.Add("  $name ($ver, Online): installer-named blocker - would upgrade the agent."); continue }
            if ($dc.PSObject.Properties.Name -contains 'RebootRequired' -and $dc.RebootRequired) {
                $log.Add("  $name ($ver, Online): installer-named blocker, but RebootRequired=True - the agent upgrade cannot finish until that machine reboots. NOT attempted.")
                $blocked += "$name (installer-named; endpoint needs a reboot before its agent can upgrade)"
                continue
            }
            try {
                $log.Add("  $name ($ver, Online): named by the installer as blocking the upgrade - upgrading its agent.")
                Install-VBRDiscoveredComputerAgent -DiscoveredComputer $dc -ErrorAction Stop | Out-Null
                $sw = [System.Diagnostics.Stopwatch]::StartNew(); $done = $false
                while ($sw.Elapsed.TotalSeconds -lt $UpgradeWait) {
                    Start-Sleep -Seconds 30
                    $now = Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $name } | Select-Object -First 1
                    if ($now -and [string]$now.AgentVersion -ne $ver) {
                        $log.Add("  $name agent $ver -> $([string]$now.AgentVersion)."); $upgraded += $name; $done = $true; break
                    }
                    if ($now -and $now.PSObject.Properties.Name -contains 'RebootRequired' -and $now.RebootRequired) {
                        $log.Add("  $name now reports RebootRequired=True - the upgrade staged but that machine must reboot to finish.")
                        $blocked += "$name (installer-named; agent upgrade staged, endpoint needs a reboot)"
                        $done = $true; break
                    }
                }
                if (-not $done) {
                    $log.Add("  $name agent upgrade did not report a new version within $UpgradeWait s.")
                    $why = @(Get-AgentDeployFailure -AgentName $name)
                    foreach ($d in $why) { $log.Add("    DEPLOY: $d") }
                    if ($why -join ' ' -match 'Error 1714') {
                      $log.Add("    CAUSE: MSI 1714 - the OLD agent cannot be uninstalled on $name. Its Windows Installer registration is broken. The BDR push is working correctly; the endpoint needs its Veeam Agent registration repaired before any upgrade can land. Run the endpoint repair script against $name.")
                    }
                    $blocked += "$name (installer-named; agent upgrade did not complete in $UpgradeWait s)"
                }
            } catch {
                $log.Add("  $name agent upgrade failed: $($_.Exception.Message)")
                $blocked += "$name (installer-named; agent upgrade failed: $($_.Exception.Message))"
            }
            continue
        }

        # Not Online - cannot be upgraded from here, and must not be removed.
        $log.Add("  $name ($ver, $st): named by the installer as blocking the upgrade, but it is not Online so its agent cannot be upgraded from here. NOT REMOVING IT - this script never removes a registration, and one that is merely unreachable may still be a live server. NOTE: Veeam SETUP is what blocks here, not this script - setup refuses to install while an outdated agent is registered (report severity=error, 'Outdated Veeam Agents'). Bring that machine online so its agent can be upgraded, and this device will proceed on the next run.")
        if ($rpCount -gt 0) { $log.Add("    NOTE: $name has $rpCount restore point(s) on this device. Removing its registration would drop a protected machine out of its job.") }
        $blocked += "$name ($st, installer-named, agent $ver - unreachable; needs the machine online to upgrade, or a deliberate decision to remove$(if ($rpCount -gt 0) { " - WARNING: $rpCount restore points exist" }))"
        continue
    }

    if ($null -eq $age) { $blocked += "$name (offline, never connected - manual review)"; $log.Add("  $name ($ver, Offline, never connected): NOT removed."); continue }
    if ($age -lt $StaleDays) { $blocked += "$name (offline $age d, under the $StaleDays d threshold)"; $log.Add("  $name ($ver, Offline $age d): NOT removed - under threshold."); continue }

    $hasBk = $false; $rpAge = $null
    try {
      $newest = $null
      foreach ($b in @(Get-VBRBackup -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -match [regex]::Escape($name) })) {
        $pts = @(Get-VBRRestorePoint -Backup $b -ErrorAction SilentlyContinue)
        if ($pts.Count -eq 0) { continue }
        $hasBk = $true
        $n = ($pts | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime
        if ($n -and (-not $newest -or $n -gt $newest)) { $newest = $n }
      }
      if ($newest) { $rpAge = [int]((Get-Date) - $newest).TotalDays }
    } catch { $hasBk = $true; $rpAge = 0; $log.Add("  Could not verify backups for '$name' - treating as RECENTLY PROTECTED.") }

    if ($hasBk -and $null -ne $rpAge -and $rpAge -lt $RpDays) {
      $blocked += "$name (offline $age d, newest restore point $rpAge d old - under the $RpDays d threshold)"
      $log.Add("  $name ($ver, Offline $age d): newest restore point is $rpAge d old - NOT removed."); continue
    }
    # THIS SCRIPT DOES NOT REMOVE AGENT REGISTRATIONS. EVER.
    # Removal was the proactive sweep's last remaining path and it is gone.
    # An offline registration is not evidence that a machine is dead - it is
    # evidence the agent has not checked in. <SERVER34> made the point:
    # <HOSTNAME>.<CLIENT>.local looked like a removal candidate and turned out to be
    # ONLINE with 400 restore points in a live job. Nothing about a stale
    # timestamp is worth that risk.
    # Stale registrations are REPORTED so a person can decide. Backup files
    # were never affected by removal either way; the registration is what
    # keeps a machine inside its job.
    $desc = if ($hasBk) { "newest restore point $rpAge d old" } else { 'no backups' }
    $log.Add("  $name ($ver, Offline $age d, last seen $last, $desc): stale registration - REPORTED, NOT REMOVED. This script never removes a registration; a person decides that.")
    $blocked += "$name (agent $ver, offline $age d, $desc - stale, needs a human decision)"
  }

  @{ ok=$true; log=@($log); removed=@($removed); upgraded=@($upgraded); blocked=@($blocked) } | ConvertTo-Json -Depth 4 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; log=@($log); removed=@($removed); upgraded=@($upgraded); blocked=@($blocked) } | ConvertTo-Json -Depth 4 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix $prefix
}

function Invoke-AgentRemediation {
    param([string[]]$TargetNames = @(), [int]$StaleDays = 180, [int]$RestorePointDays = 60, [bool]$ReportOnly = $false)

    $result = @{ Upgraded = @(); Removed = @(); Blocked = @() }
    $r = $null
    try {
        $r = Invoke-AgentRemediationQuery -TargetNames $TargetNames -StaleDays $StaleDays `
                -RestorePointDays $RestorePointDays -ReportOnly $ReportOnly
    } catch {
        Write-Log "Agent remediation query failed: $($_.Exception.Message)" 'WARN'
        return $result
    }
    if ($null -eq $r) { return $result }
    foreach ($l in @($r.log)) { if ($l) { Write-Log $l } }
    if ($r.skipped) { Write-Log "Agent remediation skipped: $($r.skipped)" 'WARN'; return $result }
    if (-not $r.ok) { Write-Log "Agent remediation error: $($r.error)" 'WARN' }

    $result.Removed  = @($r.removed)
    $result.Upgraded = @($r.upgraded)
    $result.Blocked  = @($r.blocked)

    if ($result.Removed.Count -gt 0) {
        Write-Log ("AGENT CLEANUP - removed {0} stale registration(s): {1}" -f $result.Removed.Count, ($result.Removed -join '; ')) 'WARN'
        Write-Log 'NOTE: registration removal only - backup files remain on the repository. Removal from a Custom protection group is permanent.' 'WARN'
    }
    if ($result.Upgraded.Count -gt 0) {
        Write-Log ("AGENT CLEANUP - upgraded {0} agent(s): {1}" -f $result.Upgraded.Count, ($result.Upgraded -join '; '))
    }
    return $result
}

function Get-SetupReportAgentBlockers {
    param([string]$ReportPath)
    $out = @{ Names = @(); Titles = @(); OtherErrors = @() }
    if (-not (Test-Path -LiteralPath $ReportPath)) { return $out }
    try {
        [xml]$rpt = Get-Content -LiteralPath $ReportPath -Raw
        foreach ($i in @($rpt.report.issue)) {
            if ([string]$i.severity -ne 'error') { continue }
            $title = [string]$i.title
            $out.Titles += $title
            $objs = @($i.object)
            if ($objs.Count -gt 0 -and $title -match '(?i)agent') {
                foreach ($o in $objs) {
                    $raw = [string]$o.name
                    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                    $out.Names += ($raw -split '\s*\(')[0].Trim()
                }
            } else { $out.OtherErrors += $title }
        }
    } catch { Write-Log "Could not parse setup report ${ReportPath}: $($_.Exception.Message)" 'WARN' }
    return $out
}

function Get-PostUpgradeCopyStatus {
    param($BaselineCopyJobs, $LiveSessions, [datetime]$SinceUtc)

    $out = @{ Failed = @(); Succeeded = @(); NotYet = @(); PreBroken = @() }
    foreach ($cj in @($BaselineCopyJobs)) {
        $healthy = ([string]$cj.lastResult -in @('Success','Warning','None'))
        if (-not $healthy) { $out.PreBroken += [string]$cj.name; continue }
        if (-not [bool]$cj.enabled) { continue }

        $post = @($LiveSessions) |
            Where-Object { [string]$_.jobName -eq [string]$cj.name -and
                           [datetime]::Parse([string]$_.createdUtc).ToUniversalTime() -gt $SinceUtc } |
            Sort-Object { [datetime]::Parse([string]$_.createdUtc) } -Descending | Select-Object -First 1
        if (-not $post) { $out.NotYet += [string]$cj.name }
        elseif ([string]$post.result -eq 'Failed') { $out.Failed += ("{0} (session {1}, {2})" -f $cj.name, $post.createdUtc, $post.result) }
        else { $out.Succeeded += [string]$cj.name }
    }
    return $out
}

# =============================================================================
# SERVICE / INSTALLER HANDLING
# =============================================================================

function Stop-VeeamMaintenanceWorkers {
    $killed = @()
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='Veeam.Backup.Manager.exe'" -ErrorAction SilentlyContinue)) {
            $cl = [string]$p.CommandLine
            if ($cl -match $MaintenanceVerbs) {
                $verb = ([regex]::Match($cl, $MaintenanceVerbs)).Value
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                $killed += "$verb(PID $($p.ProcessId))"
            }
        }
    } catch { }
    return ,$killed
}

function Test-StuckInfraRescan {
    # A STUCK INFRASTRUCTURE RESCAN MEANS THE SERVICE WILL NEVER STOP.
    #
    # Proven on <SERVER31>, 2026-09-23. STARTINFRARESCAN (PID 5796) ran for
    # THIRTEEN HOURS, holding VeeamBackupSvc open. Killing it does not help -
    # the service log says verbatim "New rescan job will be started. Reason:
    # Session ... was stopped." and a replacement appeared within 60 s.
    # Rebooting does not help either: the process restarted 3 minutes after the
    # 03:31 boot and was stuck again.
    #
    # Root cause at that site, for reference: its S3 object-storage repository
    # cannot be scanned. The service log shows "PrioritizedGateHosts ... for
    # Repository S3 ...:" resolving EMPTY despite a gateway being configured,
    # and dozens of "[TempAccessManager] Checking access rights to object
    # <repo-id> ... access denied". Backblaze B2 answered on 443, so it is not
    # a network fault - it is internal to Veeam and needs a support case.
    #
    # The script cannot repair that. What it CAN do is stop spending 900
    # seconds and a wasted reboot discovering it on every single run. 120
    # devices did exactly that in the 2026-09-23 wave.
    param([int]$MaxMinutes = 15)
    $stuck = @()
    try {
        foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='Veeam.Backup.Manager.exe'" -ErrorAction SilentlyContinue)) {
            $m = [regex]::Match([string]$proc.CommandLine, 'START[A-Z]+')
            if (-not $m.Success) { continue }
            if ($m.Value -notin @('STARTINFRARESCAN','STARTHVCTPRESCAN','STARTDISCOVER')) { continue }
            $age = $null
            try { $age = ((Get-Date) - $proc.CreationDate).TotalMinutes } catch { }
            if ($null -ne $age -and $age -gt $MaxMinutes) {
                $stuck += [pscustomobject]@{ Verb = $m.Value; Pid = $proc.ProcessId; AgeMinutes = [math]::Round($age, 1) }
            }
        }
    } catch { }
    return $stuck
}

function Test-VeeamServiceWedged {
    # A *Pending status is only meaningful if it PERSISTS.
    #
    # v4.6 and earlier treated ANY *Pending state as permanently wedged and
    # rebooted immediately. That was wrong: 28 Veeam services start at once
    # after a boot and several legitimately sit in StartPending for a minute
    # or more. <SERVER50> was declared wedged and rebooted, and was then
    # found with all 28 services Running, 9392 listening, a normal service log
    # and zero SCM error events in 12 hours. It had recovered on its own - the
    # script caught it mid-transition.
    #
    # Worse, it compounds: reboot -> services still coming up -> next run sees
    # StartPending -> reboots again. That loop is a plausible contributor to
    # the 120 clean-boot retries in the 2026-09-22 wave.
    #
    # So: wait, re-check, and only call it wedged if it survives the grace
    # period.
    param([int]$GraceSeconds = 180, [int]$PollSeconds = 15)

    $pendingStates = @('StopPending','StartPending','PausePending','ContinuePending')
    $first = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
               Where-Object { $_.Status -in $pendingStates })
    if ($first.Count -eq 0) { return $null }

    Write-Log ("Veeam service(s) mid-transition: {0}. Waiting up to {1} s before calling this wedged." -f `
        (($first | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', '), $GraceSeconds) 'WARN'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $GraceSeconds) {
        Start-Sleep -Seconds $PollSeconds
        $now = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Status -in $pendingStates })
        if ($now.Count -eq 0) {
            Write-Log ("Services settled after {0:n0} s - NOT wedged, continuing." -f $sw.Elapsed.TotalSeconds)
            return $null
        }
    }

    $still = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
               Where-Object { $_.Status -in $pendingStates })
    if ($still.Count -eq 0) { return $null }
    return (($still | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')
}

function Test-WedgeRebootAlreadyTried {
    # Returns the previous wedge-reboot record, or $null. A device that has
    # already been rebooted for a wedged service and comes back wedged will
    # not be helped by a second reboot - it needs a person. Without this the
    # script burns a reboot every scheduled run, forever.
    if (-not (Test-Path -LiteralPath $WedgeMarkerFile)) { return $null }
    try { return (Get-Content -LiteralPath $WedgeMarkerFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-WedgeRebootMarker {
    param([string]$Detail)
    try {
        [pscustomobject]@{
            rebootedUtc = (Get-Date).ToUniversalTime().ToString('o')
            detail      = $Detail
            bootUtc     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $WedgeMarkerFile -Encoding UTF8 -Force
    } catch { Write-Log "Could not write the wedge marker: $($_.Exception.Message)" 'WARN' }
}

function Clear-WedgeRebootMarker {
    if (Test-Path -LiteralPath $WedgeMarkerFile) {
        Remove-Item -LiteralPath $WedgeMarkerFile -Force -ErrorAction SilentlyContinue
        Write-Log 'Services are healthy - previous wedge-reboot marker cleared.'
    }
}

function Restore-VeeamServiceRecovery {
    if (-not (Test-Path -LiteralPath $FailureActionsFile)) { return }
    $restored = 0
    $prevEap = $ErrorActionPreference
    try {
        $saved = Get-Content -LiteralPath $FailureActionsFile -Raw | ConvertFrom-Json
        $ErrorActionPreference = 'Continue'
        foreach ($p in $saved.PSObject.Properties) {
            $svcName = $p.Name; $acts = [string]$p.Value.actions; $reset = [int]$p.Value.reset
            if ([string]::IsNullOrWhiteSpace($acts)) { continue }
            & cmd.exe /c "sc failure `"$svcName`" reset= $reset actions= $acts" 2>&1 | Out-Null
            $restored++
        }
        $ErrorActionPreference = $prevEap
        Remove-Item -LiteralPath $FailureActionsFile -Force -ErrorAction SilentlyContinue
        Write-Log "SCM recovery actions restored on $restored Veeam service(s)."
    } catch {
        $ErrorActionPreference = $prevEap
        Write-Log "Could not restore SCM recovery actions: $($_.Exception.Message)." 'WARN'
    }
}

function Disable-VeeamServiceRecovery {
    $saved = [ordered]@{}
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    foreach ($s in @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue)) {
        $q = ((& sc.exe qfailure $s.Name 2>$null) -join "`n")
        $acts = @()
        foreach ($m in [regex]::Matches($q, '(?i)(RESTART|RUN PROCESS|REBOOT)\s*--\s*Delay\s*=\s*(\d+)')) {
            $verb = 'restart'
            if ($m.Groups[1].Value -match '(?i)RUN')    { $verb = 'run' }
            if ($m.Groups[1].Value -match '(?i)REBOOT') { $verb = 'reboot' }
            $acts += ("{0}/{1}" -f $verb, $m.Groups[2].Value)
        }
        $reset = 0
        if ($q -match '(?i)RESET_PERIOD \(in seconds\)\s*:\s*(\d+)') { $reset = [int]$Matches[1] }
        $saved[$s.Name] = [ordered]@{ actions = ($acts -join '/'); reset = $reset }
        & cmd.exe /c "sc failure `"$($s.Name)`" reset= 0 actions= `"`"" 2>&1 | Out-Null
    }
    $ErrorActionPreference = $prevEap
    $saved | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $FailureActionsFile -Encoding UTF8 -Force
    Write-Log "SCM auto-restart cleared on $($saved.Count) Veeam service(s) for the install window."
}

function Repair-DisabledVeeamServices {
    # A DISABLED CORE SERVICE IS NOT A CONFIGURATION CHOICE ON A BDR.
    # The exit guard only ever looked at services with StartType Automatic,
    # so a service set to Disabled was invisible to it - it never tried, never
    # reported, and the device simply never backed up again. Six devices in
    # the 2026-09-23 fleet were in exactly that state (<SERVER12>, <SERVER40>,
    # <SERVER41>, <SERVER42>, <SERVER43>, <SERVER44>) with VeeamBackupSvc Disabled, and no number
    # of script re-runs would ever have touched them.
    #
    # Scope is deliberately narrow: only the services a BDR cannot function
    # without. Everything else is left alone, because Veeam ships plenty of
    # optional services (AHV, AWS, Azure, GCP, Kasten and so on) that a site
    # may legitimately have turned off.
    $core = @('VeeamBackupSvc','VeeamTransportSvc','VeeamDeploySvc','VeeamDistributionSvc',
              'VeeamCatalogSvc','VeeamBrokerSvc','VeeamMountSvc')
    $found = @()
    foreach ($n in $core) {
        $svc = $null
        try { $svc = Get-Service -Name $n -ErrorAction SilentlyContinue } catch { }
        if (-not $svc) { continue }
        $start = $null
        try { $start = (Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue).StartMode } catch { }
        if ($start -ne 'Disabled') { continue }
        $found += $n
        Write-Log "CORE VEEAM SERVICE DISABLED: $n. A BDR cannot back anything up in this state and the exit guard - which only starts auto-start services - would never have touched it." 'ERROR'
        if (-not $FixDisabledSvc) {
            Write-Log "  fixDisabledServices=0 - not changing it. This device will not back up until someone does." 'ERROR'
            continue
        }
        try {
            $mode = if ($n -eq 'VeeamBackupSvc') { 'delayed-auto' } else { 'auto' }
            & sc.exe config $n start= $mode | Out-Null
            Start-Sleep -Seconds 2
            Start-Service -Name $n -ErrorAction Stop
            Start-Sleep -Seconds 10
            $now = (Get-Service -Name $n -ErrorAction SilentlyContinue).Status
            if ($now -eq 'Running') { Write-Log "  $n re-enabled ($mode) and started." 'WARN' }
            else { Write-Log "  $n re-enabled ($mode) but is '$now' - check this device." 'ERROR' }
        } catch {
            Write-Log "  $n could not be re-enabled: $($_.Exception.Message). THIS DEVICE IS NOT BACKING UP." 'ERROR'
        }
    }
    if ($found.Count -eq 0) { return }
    Write-Log ("Disabled core service(s) handled: {0}" -f ($found -join ', ')) 'WARN'
}

function Repair-VeeamServiceState {
    param([int]$SettleSeconds = 25)

    $disabled = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Disabled' -and $_.Name -ne 'VeeamMBPDeploymentService' })
    if ($disabled.Count -gt 0) {
        Write-Log ("Re-enabling {0} Disabled Veeam service(s): {1}" -f $disabled.Count, (($disabled | Select-Object -ExpandProperty Name) -join ', ')) 'WARN'
        foreach ($s in $disabled) {
            try { Set-Service -Name $s.Name -StartupType Automatic -ErrorAction Stop }
            catch { Write-Log "  $($s.Name): enable failed - $($_.Exception.Message)" 'WARN' }
        }
    }

    $down = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -eq 'Stopped' })
    if ($down.Count -eq 0 -and $disabled.Count -eq 0) { Write-Log 'All auto-start Veeam services already running.'; return }

    $ordered = @($down | Where-Object { $_.Name -eq 'VeeamBackupSvc' }) +
               @($down | Where-Object { $_.Name -ne 'VeeamBackupSvc' })
    if ($ordered.Count -gt 0) {
        Write-Log ("Starting {0} stopped auto-start Veeam service(s)." -f $ordered.Count) 'WARN'
        foreach ($s in $ordered) {
            try { Start-Service -Name $s.Name -ErrorAction Stop }
            catch { Write-Log "  $($s.Name): start failed - $($_.Exception.Message)" 'WARN' }
        }
        Start-Sleep -Seconds $SettleSeconds
    }

    $still = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' })
    if ($still.Count -gt 0) {
        Write-Log ("Still not running: {0}" -f (($still | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')) 'WARN'
    } else { Write-Log 'All auto-start Veeam services running.' }
}

function Stop-VeeamForUpgrade {
    param([int]$TimeoutSeconds = 600)

    Disable-VeeamServiceRecovery

    $pre = Stop-VeeamMaintenanceWorkers
    if ($pre.Count -gt 0) { Write-Log ("Cleared {0} maintenance worker(s) before stopping: {1}" -f $pre.Count, ($pre -join ', ')) }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    # USE Stop-Service -Force, NOT sc.exe stop.
    # sc.exe stop is a fire-and-forget control request: it returns immediately
    # and does nothing about dependent services. Stop-Service -Force walks the
    # dependency tree, stops dependents first, and blocks until the service is
    # actually down.
    #
    # That difference is the whole problem. Proven on a device from the stuck
    # population: the script's sc.exe approach timed out at 900 s with
    # STARTINFRARESCAN apparently holding it, while a plain
    # "Stop-Service VeeamBackupSvc -Force" on the SAME box reached Stopped in a
    # few minutes. The rescan was never the blocker - the stop request was
    # simply never going to succeed with dependents still running.
    $others = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'VeeamBackupSvc' -and $_.Status -ne 'Stopped' })
    if ($others.Count -gt 0) {
        Write-Log ("Stopping {0} auxiliary Veeam service(s) (Stop-Service -Force, waits for each)." -f $others.Count)
        $stopProblems = @()
        foreach ($s in $others) {
            try { Stop-Service -Name $s.Name -Force -ErrorAction Stop -WarningAction SilentlyContinue }
            catch { $stopProblems += "$($s.Name): $($_.Exception.Message)" }
        }
        # One summary line rather than up to 26 - the individual failures are
        # almost never actionable and they cost the tail of the log.
        if ($stopProblems.Count -gt 0) {
            Write-Log ("  {0} auxiliary service(s) did not stop cleanly: {1}" -f `
                $stopProblems.Count, (($stopProblems | Select-Object -First 3) -join '; ')) 'WARN'
        }
    }

    # Anything still listed as depending on VeeamBackupSvc must go first.
    try {
        $svcObj = Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue
        $deps = @($svcObj.DependentServices | Where-Object { $_.Status -ne 'Stopped' })
        if ($deps.Count -gt 0) {
            Write-Log ("Stopping {0} dependent service(s) of VeeamBackupSvc: {1}" -f $deps.Count, (($deps | Select-Object -ExpandProperty Name) -join ', '))
            foreach ($d in $deps) {
                try { Stop-Service -Name $d.Name -Force -ErrorAction Stop -WarningAction SilentlyContinue }
                catch { Write-Log ("  {0}: {1}" -f $d.Name, $_.Exception.Message) 'WARN' }
            }
        }
    } catch { }

    $stopJob = $null
    $svc = Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Log "Stopping VeeamBackupSvc with Stop-Service -Force (up to $TimeoutSeconds s; the installer itself allows only 300 s) ..."
        # Stop-Service -Force blocks with no timeout of its own, so run it in a
        # job and bound it here. This is the call that works; sc.exe stop is
        # the one that did not.
        $stopJob = Start-Job -ScriptBlock {
            try { Stop-Service -Name 'VeeamBackupSvc' -Force -ErrorAction Stop -WarningAction SilentlyContinue; 'stopped' }
            catch { "error: $($_.Exception.Message)" }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew(); $lastReport = 0
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 10
            $st = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
            if ($st -eq 'Stopped') { break }
            # Leave the service alone for the first StopWorkerGraceSecs. It is
            # draining its own jobs on a 10-minute internal budget; interfering
            # early only restarts dispatcher-managed sessions.
            # Do not terminate workers while Stop-Service is draining. Every
            # dispatcher-managed verb respawns on kill, and the proper stop
            # clears them on its own - a manual restart on a stuck device
            # showed the rescan disappearing as the service went down.
            if ($false) { }
            # NO EARLY BAIL ON A LONG-RUNNING RESCAN. v4.24 abandoned the
            # stop at 5 minutes if a rescan looked stuck; with Stop-Service
            # -Force that stop now succeeds, so bailing would throw away a run
            # that was about to work.
            if (($sw.Elapsed.TotalSeconds - $lastReport) -ge 120) {
                $lastReport = $sw.Elapsed.TotalSeconds
                $holding = @()
                try {
                    $holding = @(Get-CimInstance Win32_Process -Filter "Name='Veeam.Backup.Manager.exe'" -ErrorAction SilentlyContinue |
                        ForEach-Object {
                            $m = [regex]::Match([string]$_.CommandLine, 'START[A-Z]+')
                            if ($m.Success) { "$($m.Value)(PID $($_.ProcessId))" }
                        })
                } catch { }
                Write-Log ("  VeeamBackupSvc still {0} after {1:n0} s{2}" -f $st, $sw.Elapsed.TotalSeconds,
                    $(if ($holding.Count) { " - workers present: " + ($holding -join ', ') } else { ' - no workers running' }))

                # KILL THE WEDGED WORKER - this is the step that was disabled.
                # After StopWorkerGraceSecs, a Veeam.Backup.Manager.exe still
                # running is the thing holding the stop. Killing that specific
                # PID is exactly what cleared it by hand on <SERVER31> and
                # every stuck box since. The old code left it alone on the
                # theory the worker would respawn - but at the STOP stage the
                # service is trying to exit, so it does NOT respawn; it just
                # waits on that process. Leaving it alone is why the stop sat
                # for the full budget and failed.
                if ($sw.Elapsed.TotalSeconds -ge $StopWorkerGraceSecs) {
                    try {
                        $stuck = @(Get-CimInstance Win32_Process -Filter "Name='Veeam.Backup.Manager.exe'" -ErrorAction SilentlyContinue)
                        foreach ($w in $stuck) {
                            $vb = [regex]::Match([string]$w.CommandLine, 'START[A-Z]+').Value
                            Write-Log ("  Terminating wedged worker $vb (PID $($w.ProcessId)) that is holding the service stop.") 'WARN'
                            Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue
                        }
                        if ($stuck.Count -gt 0) { Start-Sleep -Seconds 15 }
                    } catch { }
                }
            }
        }
    }
    $ErrorActionPreference = $prevEap

    if ($stopJob) {
        $r = $null
        try { $r = Receive-Job -Job $stopJob -ErrorAction SilentlyContinue } catch { }
        if ($r) { Write-Log ("Stop-Service result: {0}" -f ($r -join '; ')) }
        try { Remove-Job -Job $stopJob -Force -ErrorAction SilentlyContinue } catch { }
    }
    $final = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
    if ($final -ne 'Stopped') {
        Write-Log "VeeamBackupSvc is still '$final' after $TimeoutSeconds s." 'WARN'
        Restore-VeeamServiceRecovery
        # CRITICAL: 26 auxiliary services were stopped at the top of this
        # function. If we leave now without restarting them the box backs up
        # NOTHING until something else reboots it. On <SERVER56> they sat
        # down for 10 minutes and only came back because of the retry reboot.
        Write-Log 'Stop failed - bringing the auxiliary services back up before returning, so this box is not left unprotected.' 'WARN'
        Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs
        return $false
    }
    Write-Log 'VeeamBackupSvc stopped cleanly.'
    return $true
}

function Write-UpgradeState {
    # THE DEVICE IS THE SOURCE OF TRUTH. WRITE IT DOWN.
    #
    # Every fleet number this project produced was wrong at some point, and
    # never because the fleet was wrong:
    #   - NinjaOne truncates activity output at 10,003 characters, and the
    #     runs that SUCCEED produce the longest logs, so completions were
    #     invisible.
    #   - v2/queries/software lags. Confirmed 41 hours on <SERVER33>:
    #     same installDate, version field moved 13.0.2.29 -> 13.1.1.18 with no
    #     intervening install. An earlier "up to 2 hours" assumption was
    #     carried into three reports.
    #   - v2/activities caps at 400 pages, which covered roughly 12 hours, so
    #     "never received the script" meant "ran outside the window I could
    #     see".
    #
    # All three are properties of the reporting path, not the device. The
    # device knows its own version and its own outcome the moment the run
    # ends. Ninja-Property-Set writes that straight into a custom field from
    # the device itself - no cache, no truncation, no paging - and one
    # v2/queries/custom-fields call then reads the true state of all 267.
    #
    # Format is deliberately one line, pipe-delimited, parseable:
    #   <schema>|<utc>|<script ver>|<arp row>|<file ver>|<state>|<exit>|<detail>
    param(
        [string]$State,
        [int]$Exit,
        [string]$Detail = ''
    )
    if (-not (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue)) { return }
    try {
        $arp = $null; $fv = $null
        try { $arp = Get-VbrProductArpVersion } catch { }
        try { $fv = [string](Get-InstalledVbrBuild).Build } catch { }
        $d = ($Detail -replace '\|', '/') -replace '\s+', ' '
        if ($d.Length -gt 300) { $d = $d.Substring(0, 300) }
        $line = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f `
            'v1',
            (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
            $ScriptVersionTag,
            $(if ($arp) { $arp } else { 'none' }),
            $(if ($fv)  { $fv }  else { 'none' }),
            $State, $Exit, $d
        Ninja-Property-Set $StateFieldName $line 2>$null | Out-Null
        Write-Log "State written to custom field '$StateFieldName': $State (arp=$(if($arp){$arp}else{'none'}))"
    } catch {
        Write-Log "Could not write the state field: $($_.Exception.Message)" 'WARN'
    }
}

function Get-NinjaSecureField {
    param([string]$FieldName)
    if (Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue) {
        try {
            $v = Ninja-Property-Get $FieldName 2>$null
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        } catch { }
    }
    $cliCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'NinjaRMMAgent\ninjarmm-cli.exe'),
        (Join-Path $env:ProgramFiles        'NinjaRMMAgent\ninjarmm-cli.exe'),
        'C:\ProgramData\NinjaRMMAgent\ninjarmm-cli.exe'
    )
    foreach ($cli in $cliCandidates) {
        if (Test-Path -LiteralPath $cli) {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $v = & $cli get $FieldName 2>$null
            $ErrorActionPreference = $prevEap
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return ([string]$v).Trim() }
        }
    }
    return $null
}

function Test-LocalCredential {
    # One real logon attempt. <SERVER18> proved the cost of skipping it: the
    # task registered with a stale password, Windows rejected it at launch
    # (Security 4625, substatus 0xC000006A = bad password), the task never ran,
    # and LastTaskResult 0 read as success. Fails here, before an 18 GB download.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams','',
        Justification='PrincipalContext.ValidateCredentials() takes a plaintext string; a SecureString would only be marshalled back inside this function. Never logged, nulled in finally.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword','Password',
        Justification='The .NET API requires a plaintext string.')]
    param([string]$User, [string]$Password)
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine', $env:COMPUTERNAME)
        try { return [bool]$ctx.ValidateCredentials($User, $Password) }
        finally { $ctx.Dispose() }
    } catch {
        Write-Log "Credential pre-validation could not run ($($_.Exception.Message)) - proceeding; the task-launch check still catches a bad password." 'WARN'
        return $true
    }
}

function Write-FailedComponentSummary {
    param([datetime]$SinceUtc)
    $found = 0
    foreach ($pl in @(Get-ChildItem -LiteralPath $LogFolder -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)^veeam.*\.log$' -and
                           $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc })) {
        $t = Get-Content -LiteralPath $pl.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -match 'Installation operation failed|error status: 1603') {
            $why = if ($t -match 'MsiSystemRebootPending = 1') { ' (a reboot became pending mid-install - the reboot below clears it)' } else { '' }
            Write-Log "  COMPONENT FAILED: $($pl.BaseName)$why" 'WARN'
            $found++
        }
    }
    if ($found -eq 0) { Write-Log '  No individual component log identified the failure.' 'WARN' }
}

function Invoke-IsoDownload {
    param([string]$Url, [string]$Destination)
    $partial = "$Destination.partial"
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        Write-Log 'Downloading via curl.exe (resume-capable).'
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $curlOut = & $curl -L --fail --silent --show-error --retry 5 --retry-delay 20 -C - -o $partial $Url 2>&1
        $curlExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        foreach ($line in @($curlOut)) { if ("$line".Trim()) { Write-Log "curl: $("$line".Trim())" 'WARN' } }
        if ($curlExit -eq 0 -and (Test-Path -LiteralPath $partial)) {
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        }
        Write-Log "curl exited $curlExit; falling back to BITS." 'WARN'
    }
    try {
        Start-BitsTransfer -Source $Url -Destination $partial -ErrorAction Stop
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        return
    } catch { Write-Log "BITS failed ($($_.Exception.Message)); falling back to WebClient." 'WARN' }
    (New-Object System.Net.WebClient).DownloadFile($Url, $partial)
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Test-IsoHash {
    param([string]$Path, [string]$Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-Log "SHA256 computed: $actual"
    return ($actual -eq $Expected.Trim().ToUpper())
}

function Expand-IsoToLocal {
    param([string]$IsoPath, [string]$Destination, [string]$InstallerRelativePath)
    $rel = if ($InstallerRelativePath) { $InstallerRelativePath } else { $InstallerRelPath }
    $installer = Join-Path $Destination $rel
    if (Test-Path -LiteralPath $installer) { Write-Log "Local install source already present: $Destination"; return $installer }
    if (Test-Path -LiteralPath $Destination) {
        Write-Log "Removing incomplete local install source at $Destination ..." 'WARN'
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    Mount-DiskImage -ImagePath $IsoPath | Out-Null
    $script:mountedIso = $IsoPath
    $drv = $null
    for ($i = 0; $i -lt 10 -and -not $drv; $i++) {
        Start-Sleep -Seconds 3
        $drv = (Get-DiskImage -ImagePath $IsoPath | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
    }
    if (-not $drv) { throw 'Could not resolve mounted drive letter after 30 seconds.' }
    Write-Log "Mounted at ${drv}: - copying install source to $Destination (the patch engine cannot run from read-only media) ..."

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & robocopy.exe "${drv}:\" $Destination /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    $script:mountedIso = $null

    if ($rc -ge 8) { throw "robocopy failed copying install source from ${drv}: to $Destination (exit $rc)." }
    if (-not (Test-Path -LiteralPath $installer)) { throw "Install source copied (robocopy exit $rc) but $rel is missing under $Destination." }
    Write-Log "Install source copied (robocopy exit $rc). Running setup from local disk."
    return $installer
}

function Get-InstallerEventIds {
    # The installer's event ids for this attempt, wherever setup put its result
    # document. RETURNS AN OBJECT, NOT A BARE LIST - an empty list returned
    # from a function arrives as $null (the 4.50 reboot-guard bug).
    param([datetime]$SinceUtc)
    $ids = @()
    $files = @((Join-Path $LogFolder 'installer-stderr.txt'), (Join-Path $LogFolder 'installer-stdout.txt'))
    $files += @(Get-ChildItem -LiteralPath $SetupTempFolder -Filter 'UnattendedInstallationResult_*.xml' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($f in $files) {
        try {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            if ((Get-Item -LiteralPath $f).LastWriteTime.ToUniversalTime() -lt $SinceUtc) { continue }
            $b = [System.IO.File]::ReadAllBytes($f)
            $t = if ($b.Length -gt 1 -and $b[1] -eq 0) { [System.Text.Encoding]::Unicode.GetString($b) } else { [System.Text.Encoding]::UTF8.GetString($b) }
            foreach ($m in [regex]::Matches($t, 'event\s+id="(\d+)"')) { $ids += $m.Groups[1].Value }
        } catch { }
    }
    return [pscustomobject]@{ Ids = @($ids | Select-Object -Unique) }
}

function Write-PatchFailureEvidence {
    # THE PATCH STEP FAILS SILENTLY, SO COLLECT THE EVIDENCE HERE.
    # 2026-10-01: <SERVER19>, <SERVER20>, <SERVER21>, <SERVER22>, <SERVER23> and <SERVER24> took
    # the 13.1.0.411 hop, then failed the 13.1.1.18 patch with exit 1603 and
    # NO installer event - while four other devices patched cleanly in the
    # same pass. This puts what each device knows into a few PATCHDIAG: lines
    # (reboot state, disk, and the error lines from any log the patch wrote,
    # including the install account's own TEMP, which nothing looked at), so
    # the next fleet run explains the failure without anyone logging in.
    param([datetime]$SinceUtc)
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $wu   = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $cbs  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $pfr  = 0
        try { $pfr = @((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations | Where-Object { $_ }).Count } catch { }
        $cFree = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
        Write-Log ("PATCHDIAG: last boot {0} | reboot flags WU={1} CBS={2} pendingRenames={3} | C: {4} GB free" -f `
            $boot.ToString('yyyy-MM-dd HH:mm'), $wu, $cbs, $pfr, $cFree) 'WARN'
        # Built so one missing piece cannot abort the whole capture.
        $dirs = @($SetupTempFolder, "C:\Users\$InstallAdminUser\AppData\Local\Temp")
        if ($env:WINDIR) { $dirs += (Join-Path $env:WINDIR 'Temp') }
        $logs = @(foreach ($d in $dirs) {
            if (Test-Path -LiteralPath $d) {
                Get-ChildItem -LiteralPath $d -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc -and $_.Extension -in @('.log','.txt','.xml') }
            }
        }) | Sort-Object LastWriteTime -Descending | Select-Object -First 3
        if (@($logs).Count -eq 0) {
            Write-Log 'PATCHDIAG: the patch run wrote no log anywhere - it was rejected before doing any work.' 'WARN'
        }
        foreach ($l in @($logs)) {
            Write-Log ("PATCHDIAG: {0} ({1:n0} KB)" -f $l.FullName, ($l.Length / 1KB)) 'WARN'
            $hit = @(Get-Content -LiteralPath $l.FullName -Tail 200 -ErrorAction SilentlyContinue |
                     Where-Object { $_ -match '(?i)return value 3|error|exception|fail|denied|reboot|space' } | Select-Object -Last 3)
            foreach ($h in $hit) {
                $line = ($h -replace '\s+', ' ').Trim()
                if ($line.Length -gt 220) { $line = $line.Substring(0, 220) }
                Write-Log "PATCHDIAG:   $line" 'WARN'
            }
        }
    } catch { Write-Log "Patch evidence capture failed: $($_.Exception.Message)" 'WARN' }
}

function Repair-Pwsh7 {
    # POWERSHELL 7 WHOSE RUNTIME FILES ARE GONE (<SERVER25>,
    # System.Private.CoreLib.dll missing, HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)).
    # Two routes, cheapest first:
    #   1. msiexec /fa from the cached package. Fast, no download - but Windows
    #      keeps a STRIPPED copy of large installers, so on <SERVER25> /fa failed 1603
    #      with the file still missing: the cached MSI had nothing to re-lay.
    #   2. Reinstall from a fresh, version-matched, Authenticode-verified MSI
    #      from GitHub (REINSTALL=ALL REINSTALLMODE=amus). This is what fixed
    #      <SERVER25> by hand - exit 0, pwsh 7.6.6 started.
    # Returns $true only if pwsh actually starts afterwards.
    $rows = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -match '^PowerShell 7' -and $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' })
    if ($rows.Count -eq 0) {
        Write-Log 'PowerShell 7 is damaged but has no Windows Installer registration to repair from - it needs reinstalling by hand.' 'ERROR'
        return $false
    }
    $pwOk = {
        $pw = Get-PwshPath
        if (-not $pw) { return $false }
        try { $o = & $pw -NoProfile -NonInteractive -Command 'Write-Output pwsh-ok' 2>&1; return (@($o) -contains 'pwsh-ok') } catch { return $false }
    }
    # Route 1
    foreach ($r in $rows) {
        Write-Log "Repairing $($r.DisplayName) $($r.DisplayVersion) from its cached installer (msiexec /fa) ..." 'WARN'
        $mp = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/fa $($r.PSChildName) /qn /norestart" -Wait -PassThru
        Write-Log "  msiexec exit $($mp.ExitCode)."
    }
    if (& $pwOk) { Write-Log 'PowerShell 7 starts again after the cached-package repair.'; return $true }
    Write-Log 'Cached-package repair did not restore PowerShell 7 (the cached MSI is stored stripped). Reinstalling from a fresh version-matched MSI.' 'WARN'

    # Route 2 - fresh MSI for the EXACT installed version, verified before it runs.
    $ver = ($rows | ForEach-Object { $_.DisplayVersion } | Where-Object { $_ -match '^\d+\.\d+\.\d+' } | Select-Object -First 1)
    if (-not $ver) { Write-Log 'Could not read the installed PowerShell 7 version - cannot fetch a matching MSI. Needs reinstalling by hand.' 'ERROR'; return $false }
    $ver = ($ver -split '\.')[0..2] -join '.'
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $msi = Join-Path $env:TEMP "PowerShell-$ver-win-$arch.msi"
    $url = "https://github.com/PowerShell/PowerShell/releases/download/v$ver/PowerShell-$ver-win-$arch.msi"
    try {
        Write-Log "  Downloading $url ..."
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        Invoke-IsoDownload -Url $url -Destination $msi
    } catch { Write-Log "  Download failed: $($_.Exception.Message). PowerShell 7 needs reinstalling by hand." 'ERROR'; return $false }
    $sig = Get-AuthenticodeSignature -LiteralPath $msi
    $subjOk = ($sig.Status -eq 'Valid' -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
    if (-not $subjOk) {
        Write-Log "  MSI signature is '$($sig.Status)' / '$($sig.SignerCertificate.Subject)' - NOT a valid Microsoft signature. Not installing; deleting the file." 'ERROR'
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Log "  Signature valid (Microsoft Corporation). Reinstalling PowerShell $ver ..."
    $ip = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$msi`" /qn /norestart REINSTALL=ALL REINSTALLMODE=amus" -Wait -PassThru
    Write-Log "  msiexec exit $($ip.ExitCode)."
    Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    if (& $pwOk) { Write-Log "PowerShell 7 starts again after reinstalling $ver." ; return $true }
    Write-Log 'PowerShell 7 still does not start after the reinstall - it needs reinstalling by hand.' 'ERROR'
    return $false
}

function Suspend-SpcManagementAgent {
    # THE SERVICE PROVIDER CONSOLE AGENT LOCKS VEEAM FILES DURING A PATCH.
    # VeeamManagementAgentSvc (Veeam.AC.Agent.exe) launches pwsh with the Veeam
    # module about every 10 s to poll Backup & Replication. The patch track does
    # not pre-stop services, so one of those polls is usually mid-flight when the
    # patch checks its files, and setup refuses with "unable to update the
    # following files, because they are locked by an external process" - a 1603
    # with NO installer event. <SERVER19>, 2026-10-01: proven cause and fix -
    # with this agent stopped, the patch completed to 13.1.1.18. Same signature
    # on <SERVER20>, <SERVER21>, <SERVER22>, <SERVER23>, <SERVER24>.
    # Set to Manual (not just stopped) so the exit guard's start-all-Automatic
    # sweep does not bring it straight back mid-patch, then kill any poll already
    # running. Returns the StartType to restore, or $null if there was nothing
    # to do. SPC simply loses sight of the box for the few minutes of the patch.
    $svc = Get-Service -Name 'VeeamManagementAgentSvc' -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $original = [string](Get-CimInstance Win32_Service -Filter "Name='VeeamManagementAgentSvc'" -ErrorAction SilentlyContinue).StartMode
    Write-Log 'Pausing VeeamManagementAgentSvc (SPC agent) for the patch window - it polls Veeam every ~10 s and locks the files setup needs.' 'WARN'
    try { Set-Service -Name 'VeeamManagementAgentSvc' -StartupType Manual -ErrorAction SilentlyContinue } catch { }
    try { Stop-Service -Name 'VeeamManagementAgentSvc' -Force -ErrorAction Stop } catch { Write-Log "  Could not stop the SPC agent: $($_.Exception.Message)" 'WARN' }
    Start-Sleep -Seconds 10
    $apid = (Get-CimInstance Win32_Service -Filter "Name='VeeamManagementAgentSvc'" -ErrorAction SilentlyContinue).ProcessId
    foreach ($w in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $apid -and $_.ParentProcessId -eq $apid })) {
        Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue
    }
    return $(if ($original) { $original } else { 'Auto' })
}

function Restore-SpcManagementAgent {
    # Put the SPC agent back however it was found. Always runs after the patch,
    # success or fail. StartMode strings from WMI map to Set-Service values.
    param([string]$OriginalStartMode)
    if (-not $OriginalStartMode) { return }
    $svc = Get-Service -Name 'VeeamManagementAgentSvc' -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    $map = @{ 'Auto' = 'Automatic'; 'Automatic' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }
    $st = $map[$OriginalStartMode]; if (-not $st) { $st = 'Automatic' }
    try { Set-Service -Name 'VeeamManagementAgentSvc' -StartupType $st -ErrorAction SilentlyContinue } catch { }
    if ($st -ne 'Disabled') { try { Start-Service -Name 'VeeamManagementAgentSvc' -ErrorAction SilentlyContinue } catch { } }
    Write-Log "VeeamManagementAgentSvc restored to $st."
}

function Write-InstallerResultXml {
    param([datetime]$SinceUtc)
    try {
        $xml = Get-ChildItem -LiteralPath $SetupTempFolder -Filter 'UnattendedInstallationResult_*.xml' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($xml) {
            Write-Log "Installer result XML: $($xml.FullName)"
            Write-CappedLines -Lines (Get-Content -LiteralPath $xml.FullName -ErrorAction SilentlyContinue) `
                              -Max $MaxResultXmlLines -Prefix '  RESULTXML: ' -FullPath $xml.FullName
        } else {
            # Setup often writes the result document to STDERR instead of this
            # folder - it was captured into installer-stderr.txt and echoed with
            # the INSTALLER: prefix above (<SERVER09>). The PATCH installer
            # writes NOTHING anywhere when it rejects its command line, so also
            # sweep for any log it did leave and report the newest few.
            Write-Log "No UnattendedInstallationResult_*.xml in $SetupTempFolder." 'WARN'
            $recent = @(Get-ChildItem -LiteralPath $SetupTempFolder -Filter '*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 3)
            if ($recent.Count -eq 0) {
                Write-Log "No setup log of ANY kind was written since this run started. The installer was rejected before it did any work - check the command line, not the product." 'WARN'
            } else {
                # KEEP THIS SHORT. v4.16 dumped 20-30 lines per log and ate
                # 35-39% of NinjaOne's 10,003-character activity cap, pushing
                # "Post-upgrade build:", "HOP COMPLETE" and the job-restore
                # confirmation off the end on <SERVER52>, <SERVER53> and
                # <SERVER54>. Three sites' job state became unverifiable as a
                # direct result. The value is in the return code, not in 30
                # lines of "Disposing '{GUID}'".
                foreach ($r in $recent) {
                    Write-Log "Setup log written this run: $($r.Name) ($($r.Length) bytes)"
                    $tail = @(Get-Content -LiteralPath $r.FullName -Tail 60 -ErrorAction SilentlyContinue)
                    $key  = @($tail | Where-Object { $_ -match '(?i)return value|error|fail|exception|reboot' } | Select-Object -Last 3)
                    if ($key.Count -eq 0) { $key = @($tail | Select-Object -Last 2) }
                    Write-CappedLines -Lines $key -Max 3 -Prefix '  SETUPLOG: ' -FullPath $r.FullName
                }
            }
        }
    } catch { Write-Log "Result XML capture failed: $($_.Exception.Message)" 'WARN' }

    try {
        $patch = Get-ChildItem -LiteralPath $SetupTempFolder -Filter '*Patch*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($patch) {
            $txt = Get-Content -LiteralPath $patch.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -match 'EXCEPTION|Performing rollback') {
                Write-Log "Patch pass reported a problem in $($patch.Name):" 'WARN'
                Write-CappedLines -Lines (($txt -split "`r?`n") | Select-Object -Last 15) -Max 15 -Prefix '  PATCH: ' -FullPath $patch.FullName
            } else { Write-Log "Patch pass log $($patch.Name) shows no exception." }
        }
    } catch { }
}

function Invoke-InstallerAsLocalAdmin {
    # $ArgList overrides the default answer-file invocation. The 13.1.1.18
    # patch has no Setup\Silent\ and no answer file - it is a bare Setup.exe
    # with switches - so it reuses this scheduled-task-as-local-admin
    # mechanism with a different argument list.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams','',
        Justification='Register-ScheduledTask -Password requires a plaintext string; there is no SecureString overload. The Veeam setup engine refuses LocalSystem (event id=103), so a one-shot task as the LAPS local admin is the only working install path. Never logged; nulled immediately after the install returns.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword','PlainPassword',
        Justification='Register-ScheduledTask requires a plaintext string.')]
    param([string]$InstallerExe, [string]$AnswerFile, [string]$InstallLogFolder, [string]$User, [string]$PlainPassword, [string]$ArgList)

    $wrapper = Join-Path $LogFolder 'run-installer.ps1'
    $outFile = Join-Path $LogFolder 'installer-stdout.txt'
    $errFile = Join-Path $LogFolder 'installer-stderr.txt'
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    $argSpec = if ($ArgList) { $ArgList } else {
        "'/AnswerFile', '`"$AnswerFile`"', '/SkipNetworkLogonErrors', '/LogFolder', '`"$InstallLogFolder`"'"
    }
    # RUN THE INSTALLER FROM ITS OWN FOLDER.
    # The scheduled task's working directory is the log folder, and a child
    # process inherits it. An ISO-root Setup.exe that references its payload
    # relatively (.\Setup\...) then looks in the wrong place and dies
    # immediately. That is the signature seen on <SERVER52>, <SERVER53> and
    # <SERVER54>: exit 1603 in 23-71 seconds with NO setup log, NO result
    # document and no service activity at all - rejected before doing any
    # work. The full-ISO track never hit this because
    # Setup\Silent\Veeam.Silent.Install.exe is given absolute paths.
    $installerDir = Split-Path -Parent $InstallerExe
    $wrapperBody = @"
`$p = Start-Process -FilePath '$InstallerExe' ``
    -ArgumentList $argSpec ``
    -WorkingDirectory '$installerDir' ``
    -Wait -PassThru -WindowStyle Hidden ``
    -RedirectStandardOutput '$outFile' -RedirectStandardError '$errFile'
exit `$p.ExitCode
"@
    Write-Log "Installer working directory: $installerDir"

    Set-Content -LiteralPath $wrapper -Value $wrapperBody -Encoding UTF8 -Force

    Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`"" -WorkingDirectory $LogFolder
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 3)

    $taskAccount = "$env:COMPUTERNAME\$User"
    Register-ScheduledTask -TaskName $InstallTaskName -Action $action -Settings $settings `
        -User $taskAccount -Password $PlainPassword -RunLevel Highest -Force | Out-Null
    Write-Log "One-shot installer task registered as $taskAccount (RunLevel Highest)."

    Start-ScheduledTask -TaskName $InstallTaskName

    # CONFIRM THE TASK ACTUALLY LAUNCHED. A rejected credential fails at launch:
    # the task never enters Running and LastTaskResult stays 0 from a prior
    # state - which earlier versions read as a successful install that never
    # happened (<SERVER18>).
    $launched = $false
    $s0 = 'Unknown'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TaskLaunchWaitSecs) {
        Start-Sleep -Seconds 5
        $s0 = [string](Get-ScheduledTask -TaskName $InstallTaskName -ErrorAction SilentlyContinue).State
        if ($s0 -eq 'Running') { $launched = $true; break }
    }
    if (-not $launched) {
        $ti = Get-ScheduledTaskInfo -TaskName $InstallTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue
        throw ("Installer task never entered Running within $TaskLaunchWaitSecs s (state '$s0', LastTaskResult $(if ($ti) { $ti.LastTaskResult } else { 'unknown' })). Windows rejected the scheduled-task logon - almost always a stale '$LapsFieldName' value for $env:COMPUTERNAME\$User. Check Security event 4625; substatus 0xC000006A means bad password. THE INSTALLER DID NOT RUN and nothing on this box was changed.")
    }
    Write-Log 'Installer task confirmed Running. Polling for completion (StopPending watchdog active)...'

    $deadline = (Get-Date).AddHours(3)
    $stopPendingSince = $null
    $watchdogFires = 0
    do {
        Start-Sleep -Seconds 15
        $st = [string](Get-ScheduledTask -TaskName $InstallTaskName -ErrorAction SilentlyContinue).State

        $vbs = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
        if ($vbs -eq 'StopPending') {
            if (-not $stopPendingSince) { $stopPendingSince = Get-Date }
            elseif (((Get-Date) - $stopPendingSince).TotalSeconds -ge $StopPendingGraceSecs) {
                $k = Stop-VeeamMaintenanceWorkers
                $watchdogFires++
                if ($k.Count -gt 0) {
                    Write-Log ("WATCHDOG: StopPending > {0} s - terminated {1} maintenance worker(s): {2}" -f $StopPendingGraceSecs, $k.Count, ($k -join ', ')) 'WARN'
                } elseif ($watchdogFires -le 3) {
                    Write-Log ("WATCHDOG: StopPending > {0} s but no maintenance workers found - something else holds the service." -f $StopPendingGraceSecs) 'WARN'
                }
                $stopPendingSince = Get-Date
            }
        } else { $stopPendingSince = $null }
    } while ($st -eq 'Running' -and (Get-Date) -lt $deadline)

    if ($st -eq 'Running') {
        Write-Log 'Installer task still running at 3 h limit - treating as failure.' 'ERROR'
        Stop-ScheduledTask -TaskName $InstallTaskName -ErrorAction SilentlyContinue
    }

    $info = Get-ScheduledTaskInfo -TaskName $InstallTaskName
    $code = [int]$info.LastTaskResult
    Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue

    # KEEP THE TAIL OF THE RUN READABLE.
    # NinjaOne truncates activity output at ~10,003 characters. In the
    # 2026-09-23 fleet wave, 20 devices that reached the installer lost their
    # "Post-upgrade build:", "HOP COMPLETE" and job-restore lines off the end,
    # which made a successful install indistinguishable from an unknown one
    # from the API - the single biggest obstacle to verifying job safety.
    # The installer's own stdout is the bulk of that. Veeam writes its result
    # document to STDERR, so that one still gets a real budget; stdout gets
    # only the lines that carry meaning.
    foreach ($f in @($outFile, $errFile)) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if ((Get-Item -LiteralPath $f).Length -le 0) { continue }
        $isErr  = ($f -eq $errFile)
        # Veeam writes the UnattendedInstallationResult document as UTF-16.
        # Read as single-byte it renders one character per column and the
        # failure reason is unreadable - "Setup has detected critical database
        # issues" was lost that way on <SERVER37> and <SERVER38>. Detect the BOM
        # or a null-byte pattern and decode properly.
        $raw = $null
        try {
            $bytes = [IO.File]::ReadAllBytes($f)
            $isU16 = ($bytes.Length -gt 1 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or
                      ($bytes.Length -gt 40 -and ($bytes[1] -eq 0 -and $bytes[3] -eq 0 -and $bytes[5] -eq 0))))
            $raw = if ($isU16) { [Text.Encoding]::Unicode.GetString($bytes) } else { [Text.Encoding]::UTF8.GetString($bytes) }
            if ($isU16) { Write-Log "  (decoded $([IO.Path]::GetFileName($f)) as UTF-16)" }
        } catch { $raw = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue }
        $lines  = @(($raw -replace "`0", '') -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { continue }
        Write-Log "--- installer $([IO.Path]::GetFileName($f)) ($($lines.Count) line(s)) ---"
        if ($isErr) {
            # stderr carries the <unattendedInstallationResult> document - the
            # event id and title live here and are worth every line.
            Write-CappedLines -Lines $lines -Max $MaxStdoutLines -Prefix '  INSTALLER: ' -FullPath $f
        } else {
            $keep = @($lines | Where-Object { $_ -match '(?i)error|fail|warn|exception|event id|reboot|denied|invalid|cannot|unable' } |
                     Select-Object -Last 6)
            if ($keep.Count -eq 0) { $keep = @($lines | Select-Object -Last 3) }
            Write-CappedLines -Lines $keep -Max 6 -Prefix '  INSTALLER: ' -FullPath $f
        }
    }
    return $code
}

function Invoke-PostUpgradeValidation {
    param($State)

    $fails = New-Object System.Collections.Generic.List[string]
    $copyNotYet = @()

    $bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $upgUtc  = [datetime]::Parse($State.upgradeTimeUtc).ToUniversalTime()
    if ($bootUtc -le $upgUtc) {
        $fails.Add("AWAITING REBOOT: last boot $($bootUtc.ToString('o')) predates upgrade $($State.upgradeTimeUtc).")
        return @{ Passed = $false; Failures = $fails; AwaitingReboot = $true; CopyNotYet = @() }
    }
    Write-Log "VALIDATION: Reboot confirmed (boot $($bootUtc.ToString('o')))."

    Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs

    $svcsOk = $false
    for ($i = 1; $i -le $SvcWaitAttempts; $i++) {
        $auto = @(Get-CimInstance Win32_Service -Filter "Name LIKE 'Veeam%' AND StartMode='Auto'")
        $down = @($auto | Where-Object { $_.State -ne 'Running' })
        if ($auto.Count -gt 0 -and $down.Count -eq 0) { $svcsOk = $true; break }
        Write-Log ("VALIDATION: waiting on services ({0}/{1}): {2}" -f $i, $SvcWaitAttempts, (($down | Select-Object -ExpandProperty Name) -join ', '))
        Start-Sleep -Seconds $SvcWaitSeconds
    }
    if ($svcsOk) { Write-Log 'VALIDATION: Services... PASS' }
    else {
        $downNames = (@(Get-CimInstance Win32_Service -Filter "Name LIKE 'Veeam%' AND StartMode='Auto'") |
            Where-Object { $_.State -ne 'Running' } | Select-Object -ExpandProperty Name) -join ', '
        $fails.Add("SERVICES: not running after $($SvcWaitAttempts * $SvcWaitSeconds)s: $downNames")
    }

    $minReq = $null
    if ($State.PSObject.Properties.Name -contains 'hopMinimum' -and $State.hopMinimum) { $minReq = [version]$State.hopMinimum }
    else { $minReq = [version]$State.hopTarget }
    try {
        $cur = Get-InstalledVbrBuild
        if ($cur.Build -ge $minReq) { Write-Log "VALIDATION: Build... PASS ($($cur.Build) >= minimum $minReq)" }
        else { $fails.Add("BUILD: expected >= $minReq, found $($cur.Build).") }
    } catch { $fails.Add("BUILD: query failed: $($_.Exception.Message)") }

    $live = $null
    try {
        $live = Get-VeeamLiveState
        if ($null -eq $live -or -not $live.ok) {
            $fails.Add("CONNECT: Veeam live-state query failed: $(if($live){$live.error}else{'no output'})")
            $live = $null
        } else { Write-Log 'VALIDATION: Console connect... PASS' }
    } catch { $fails.Add("CONNECT: Veeam module/session failed: $($_.Exception.Message)") }

    if ($live) {
        $bl = Get-Content -LiteralPath $State.baselineFile -Raw | ConvertFrom-Json

        try {
            if ($bl.PSObject.Properties.Name -contains 'services' -and @($bl.services).Count -gt 0) {
                $liveSvc = @{}
                foreach ($s in @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue)) { $liveSvc[[string]$s.Name] = [string]$s.StartType }
                $drift = @()
                foreach ($bs in @($bl.services)) {
                    $n = [string]$bs.name
                    if (-not $liveSvc.ContainsKey($n)) { continue }
                    if ($liveSvc[$n] -ne [string]$bs.startType) { $drift += "$n ($([string]$bs.startType)->$($liveSvc[$n]))" }
                }
                if ($drift.Count -eq 0) { Write-Log "VALIDATION: Service StartTypes... PASS ($(@($bl.services).Count))" }
                else { Write-Log ("VALIDATION: Service StartType drift on {0}: {1}" -f $drift.Count, ($drift -join ', ')) 'WARN' }
            }
        } catch { Write-Log "Service StartType comparison failed: $($_.Exception.Message)" 'WARN' }

        $liveJobs = @{}
        foreach ($j in @($live.jobs)) { $liveJobs[[string]$j.name] = [bool]$j.enabled }
        $jobFail = 0
        foreach ($bj in @($bl.jobs)) {
            if (-not $liveJobs.ContainsKey([string]$bj.name)) {
                $fails.Add("JOB MISSING: '$($bj.name)' ($($bj.type)) present at baseline, absent now."); $jobFail++
            } elseif ($liveJobs[[string]$bj.name] -ne [bool]$bj.enabled) {
                $fails.Add("JOB STATE: '$($bj.name)' enabled changed $($bj.enabled) -> $($liveJobs[[string]$bj.name])."); $jobFail++
            }
        }
        if ($jobFail -eq 0) { Write-Log "VALIDATION: Jobs... PASS ($(@($bl.jobs).Count) present, states unchanged)" }

        $liveRepos = @{}
        foreach ($r in @($live.repos)) { $liveRepos[[string]$r.name] = [string]$r.path }
        $repoFail = 0
        foreach ($br in @($bl.repos)) {
            if (-not $liveRepos.ContainsKey([string]$br.name)) {
                $fails.Add("REPO MISSING: '$($br.name)' present at baseline, absent now."); $repoFail++
            } elseif ([string]$br.type -eq 'WinLocal' -and $liveRepos[[string]$br.name] -ne [string]$br.path) {
                $fails.Add("REPO PATH: '$($br.name)' changed '$($br.path)' -> '$($liveRepos[[string]$br.name])'."); $repoFail++
            }
        }
        if ($repoFail -eq 0) { Write-Log "VALIDATION: Repositories... PASS ($(@($bl.repos).Count))" }

        $liveObj = @{}
        foreach ($o in @($live.objectRepos)) { $liveObj[[string]$o.name] = $true }
        $objFail = 0
        foreach ($bo in @($bl.objectRepos)) {
            if (-not $liveObj.ContainsKey([string]$bo.name)) {
                $fails.Add("OFFSITE REPO MISSING: object storage repo '$($bo.name)' present at baseline, absent now."); $objFail++
            }
        }
        if ($objFail -eq 0) { Write-Log "VALIDATION: Object storage repos... PASS ($(@($bl.objectRepos).Count))" }

        if ([int]$live.s3CredCount -lt [int]$bl.s3CredCount) {
            $fails.Add("S3 CREDENTIALS: baseline $($bl.s3CredCount) -> found $($live.s3CredCount).")
        } else { Write-Log "VALIDATION: S3 credentials... PASS ($($live.s3CredCount))" }

        $liveCopy = @{}
        foreach ($cj in @($live.copyJobs)) { $liveCopy[[string]$cj.name] = [bool]$cj.enabled }
        $cpFail = 0
        foreach ($bc in @($bl.copyJobs)) {
            if (-not $liveCopy.ContainsKey([string]$bc.name)) {
                $fails.Add("COPY JOB MISSING: '$($bc.name)' present at baseline, absent now."); $cpFail++
            } elseif ($liveCopy[[string]$bc.name] -ne [bool]$bc.enabled) {
                $fails.Add("COPY JOB STATE: '$($bc.name)' enabled changed $($bc.enabled) -> $($liveCopy[[string]$bc.name])."); $cpFail++
            }
        }
        if ($cpFail -eq 0) { Write-Log "VALIDATION: Copy jobs... PASS ($(@($bl.copyJobs).Count) present, states unchanged)" }

        try {
            $cs = Get-PostUpgradeCopyStatus -BaselineCopyJobs $bl.copyJobs -LiveSessions $live.sessions `
                    -SinceUtc ([datetime]::Parse($State.upgradeTimeUtc).ToUniversalTime())
            foreach ($f in $cs.Failed) { $fails.Add("OFFSITE COPY FAILED post-upgrade: $f (was healthy at baseline).") }
            foreach ($p in $cs.PreBroken) { Write-Log "VALIDATION: copy job '$p' was ALREADY failing at baseline - pre-existing, not blocking." 'WARN' }
            if ($cs.Succeeded.Count -gt 0) { Write-Log "VALIDATION: Offsite copy exercised... PASS ($($cs.Succeeded -join ', '))" }
            $copyNotYet = $cs.NotYet
            if ($copyNotYet.Count -gt 0) { Write-Log "VALIDATION: offsite copy not yet run post-upgrade for: $($copyNotYet -join ', ') - copy-watch will hold exit 0." 'WARN' }
        } catch { $fails.Add("OFFSITE COPY CHECK: failed: $($_.Exception.Message)") }

        $liveBk = @{}
        foreach ($b in @($live.backups)) { $liveBk[[string]$b.name] = $b }
        $ptFail = 0
        foreach ($bb in @($bl.backups)) {
            $n = [string]$bb.name
            if (-not $liveBk.ContainsKey($n)) { $fails.Add("BACKUP MISSING: object '$n' present at baseline, absent now."); $ptFail++; continue }
            $cur = $liveBk[$n]
            $blNewest  = if ($bb.newestUtc)  { [datetime]::Parse([string]$bb.newestUtc).ToUniversalTime() }  else { $null }
            $curNewest = if ($cur.newestUtc) { [datetime]::Parse([string]$cur.newestUtc).ToUniversalTime() } else { $null }
            # A box that misses ONE hourly cycle during its upgrade reboot is
            # normal (<SERVER13>: newest 5 h back; <SERVER14>: 8 points fewer -
            # both false positives that permanently held healthy boxes). The
            # real cases are far outside these tolerances: <SERVER15>
            # (newest point 4.5 MONTHS back) and <SERVER16> (-85 of 265 points).
            if ($curNewest -and $blNewest -and $curNewest -lt $blNewest.AddHours(-$RpBackwardsToleranceHours)) {
                $fails.Add("RESTORE POINTS: '$n' newest point went BACKWARDS $($bb.newestUtc) -> $($cur.newestUtc) (beyond the $RpBackwardsToleranceHours h tolerance)."); $ptFail++
            }
            elseif ([int]$cur.pointCount -lt ([int]$bb.pointCount * $RpCountTolerancePct)) {
                $fails.Add("RESTORE POINTS: '$n' baseline $($bb.pointCount) -> found $($cur.pointCount) - a larger drop than retention explains."); $ptFail++
            }
            elseif ([int]$cur.pointCount -lt [int]$bb.pointCount) {
                Write-Log "VALIDATION: '$n' $($bb.pointCount) -> $($cur.pointCount) point(s) - within retention tolerance, not a regression." 'WARN'
            }
        }
        if ($ptFail -eq 0) { Write-Log "VALIDATION: Restore points... PASS ($(@($bl.backups).Count) objects, no regression)" }
    }

    return @{ Passed = ($fails.Count -eq 0); Failures = $fails; AwaitingReboot = $false; CopyNotYet = $copyNotYet }
}

# --- Single instance -----------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
try   { $haveMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) { Write-Output 'HALTED: another instance of this script is already running.'; exit 2 }
$script:haveMutexRef = $mutex

# --- Transcript with rotation ----------------------------------------------------
if (-not (Test-Path -LiteralPath $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
Get-ChildItem -LiteralPath $LogFolder -Filter 'veeam-upgrade_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $LogRetention |
    Remove-Item -Force -ErrorAction SilentlyContinue

$transcript = Join-Path $LogFolder ("veeam-upgrade_{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Log "=== Veeam Upgrade v4.53 - $env:COMPUTERNAME ==="
    $pwLoc = Get-PwshPath
    Write-Log ("Identity: {0} | Host PS {1} | pwsh: {2}" -f `
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, $PSVersionTable.PSVersion,
        $(if ($pwLoc) { 'yes' } else { 'NOT FOUND' }))
    Write-Log ("Fleet target: {0}{1}. Route: <{2} -> 12.3.2.4465 -> {3}{4}" -f `
        $(if ($EnablePatch) { $PatchTargetBuild } else { $TargetBuild }),
        $(if (-not $EnablePatch) { ' (patch stage disabled - enablePatch=0)' } else { '' }),
        $GateBuild, $TargetBuild,
        $(if ($EnablePatch) { " -> $PatchTargetBuild (patch)" } else { '' }))
    if ($PreflightOnly) { Write-Log 'PREFLIGHT-ONLY MODE - no changes will be made.' 'WARN' }

    Restore-VeeamServiceRecovery
    # Before anything else: a core service set to Disabled means this device is
    # not backing up at all, whatever else the run finds.
    try { Repair-DisabledVeeamServices } catch { Write-Log "Disabled-service check failed: $($_.Exception.Message)" 'WARN' }
    try { [void](Reset-WedgedBackupService) } catch { Write-Log "Wedged-service reset failed: $($_.Exception.Message)" 'WARN' }
    Restore-VeeamJobs   # recover from any run that died or rebooted mid-upgrade
    try { Repair-AllJobsDisabled } catch { Write-Log "Self-heal check failed: $($_.Exception.Message)" 'WARN' }

    # A service stuck mid-transition never resolves and blocks every subsequent
    # run. Clear it before anything else inspects state.
    # A stuck rescan guarantees the service stop will fail. Find out in 30
    # seconds instead of 900 plus a reboot.
    $stuckScan = Test-StuckInfraRescan -MaxMinutes $StuckRescanMinutes
    if ($stuckScan.Count -gt 0 -and -not $PreflightOnly) {
        foreach ($sc in $stuckScan) {
            Write-Log ("STUCK MAINTENANCE WORKER: {0} (PID {1}) has been running {2:n1} minutes." -f $sc.Verb, $sc.Pid, $sc.AgeMinutes) 'ERROR'
        }
        Write-Log 'THIS DEVICE NEEDS A PERSON - AND A REBOOT WILL NOT FIX IT.' 'ERROR'
        Write-Log 'A maintenance worker this old never finishes, so VeeamBackupSvc can never be stopped and the upgrade cannot proceed. Killing the worker makes the service dispatch a replacement; rebooting restarts it within minutes. Both were tested and both fail.' 'ERROR'
        Write-Log 'USUAL CAUSE: an object-storage repository that cannot be scanned. Check Svc.VeeamBackup.log for "PrioritizedGateHosts ... :" resolving empty, and for "[TempAccessManager] ... access denied" against the repository id. If the S3/B2 endpoint answers on 443 but those lines are present, it is internal to Veeam and needs a support case.' 'ERROR'
        Write-Log 'Nothing on this box was changed. Jobs and services are untouched.' 'WARN'
        $exitCode = 2
        exit $exitCode
    }

    $wedged = Test-VeeamServiceWedged -GraceSeconds $WedgeGraceSecs -PollSeconds $WedgePollSecs
    if (-not $wedged) {
        Clear-WedgeRebootMarker
    } else {
        Write-Log "Veeam service(s) STILL mid-transition after $WedgeGraceSecs s: $wedged" 'ERROR'
        $prior = Test-WedgeRebootAlreadyTried
        $bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
        $rebootedSince = $false
        if ($prior -and $prior.rebootedUtc) {
            try { $rebootedSince = ($bootUtc -gt [datetime]::Parse($prior.rebootedUtc).ToUniversalTime()) } catch { }
        }
        if ($prior -and $rebootedSince) {
            # Already rebooted for this, the box HAS come back, and it is still
            # wedged. A second reboot will not help.
            Write-Log ("THIS DEVICE NEEDS A PERSON. It was already rebooted for a wedged Veeam service at {0} ({1}), has rebooted since (boot {2}), and the services are STILL mid-transition. NOT rebooting again - that would loop forever. Investigate the service state and the Veeam service log by hand." -f `
                $prior.rebootedUtc, $prior.detail, $bootUtc.ToString('o')) 'ERROR'
            exit 2
        }
        if ($PreflightOnly) { Write-Log 'Preflight-only: reboot NOT issued.' 'WARN'; exit 2 }
        Write-WedgeRebootMarker -Detail $wedged
        Invoke-ForcedReboot -Reason 'clearing a wedged Veeam service'
        exit 2
    }

    # =========================================================================
    # PHASE 0 - VALIDATION
    # =========================================================================
    if (Test-Path -LiteralPath $StateFile) {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        Write-Log "Pending validation found: hop $($state.fromBuild) -> $($state.hopTarget), upgraded $($state.upgradeTimeUtc)."

        $v = Invoke-PostUpgradeValidation -State $state

        if ($v.AwaitingReboot) {
            if ($PreflightOnly) { Write-Log 'Preflight-only: reboot NOT issued.' 'WARN'; exit 2 }
            Invoke-ForcedReboot -Reason 'completing the deferred post-upgrade reboot'
            exit 2
        }

        if (-not $v.Passed) {
            # SEPARATE DATA LOSS FROM RETENTION.
            # A MISSING job, repository or backup object means something this
            # device used to protect is no longer being protected - that must
            # always hold, and it is exactly what caught <SERVER36> losing
            # all three of its offsite copy jobs.
            # A restore-point COUNT DROP is different: the jobs, repos and
            # backups are all still there and still running, and the count fell
            # because retention rolled a chain or a job was renamed. Holding
            # those stopped 24 devices from ever reaching the current patch,
            # and a BDR left behind is a BDR whose workstations go unbacked up.
            $missing = @($v.Failures | Where-Object { $_ -match '(?i)\bMISSING\b|JOB STATE|REPO |BACKUP ' })
            $pointsOnly = ($missing.Count -eq 0 -and @($v.Failures).Count -gt 0)

            Write-Log "VALIDATION FAILED - $($v.Failures.Count) issue(s)." 'ERROR'
            foreach ($f in $v.Failures) { Write-Log "  $f" 'ERROR' }

            if ($missing.Count -gt 0) {
                Write-Log ("HOLDING: {0} of these describe something MISSING - a job, repository or backup object this device used to protect. That is not retention, and no further hop will run until a person looks." -f $missing.Count) 'ERROR'
                exit 2
            }
            if ($HoldOnPointDrop) {
                Write-Log 'HOLDING: restore-point drop only, but holdOnPointDrop=1. Marker retained.' 'ERROR'
                exit 2
            }
            if (-not $pointsOnly) {
                Write-Log 'HOLDING: validation failure could not be classified. Marker retained.' 'ERROR'
                exit 2
            }

            Write-Log 'CLEARED: every job, repository and backup object is present - the only failure is a restore-point count, which is what retention rolling a chain or a job rename looks like. Releasing this device so it can reach the current patch. The drop is recorded above; review it if the counts look wrong.' 'WARN'
            Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
            Write-Log 'Marker cleared - continuing to the build check.'
        }
        else {

        Write-Log 'VALIDATION PASSED - configuration, restore points, and offsite topology intact.'
        if ($PreflightOnly) { Write-Log 'Preflight-only: markers retained for a normal run to clear.'; exit 0 }
        Remove-Item -LiteralPath $StateFile -Force
        }

        if ($UpgradeComponents) {
            try { Invoke-AgentUpdate } catch { Write-Log "Agent update stage failed: $($_.Exception.Message)" 'WARN' }
            Write-Log '--- Managed component upgrade ---'
            try {
                $cu = Invoke-ComponentUpgrade
                if ($cu) {
                    foreach ($l in @($cu.log)) { if ($l) { Write-Log $l } }
                    if ($cu.skipped) { Write-Log "Component upgrade skipped: $($cu.skipped)" 'WARN' }
                    elseif (-not $cu.ok) { Write-Log "Component upgrade error: $($cu.error)" 'WARN' }
                }
            } catch { Write-Log "Component upgrade failed: $($_.Exception.Message)" 'WARN' }
        }

        if (@($v.CopyNotYet).Count -gt 0) {
            [pscustomobject]@{
                sinceUtc = $state.upgradeTimeUtc; jobs = @($v.CopyNotYet)
                baselineFile = $state.baselineFile; hopTarget = $state.hopTarget
            } | ConvertTo-Json | Set-Content -LiteralPath $CopyWatchFile -Encoding UTF8 -Force
            Write-Log "OFFSITE COPY WATCH opened for: $($v.CopyNotYet -join ', ')."
        }

        $now = Get-InstalledVbrBuild
        if ($now.Build -lt $TargetBuild) {
            Write-Log "Validated at $($now.Build) - below the fleet target of $(if ($EnablePatch) { $PatchTargetBuild } else { $TargetBuild }). Continuing to the next hop in this run."
        }
        elseif ($EnablePatch -and $now.Build -eq $PatchBaseBuild) {
            Write-Log "Validated at $($now.Build). The patch to $PatchTargetBuild is available - continuing to it in this run."
        }
        elseif ((Test-Path -LiteralPath $CopyWatchFile) -and $HoldForCopyWatch) {
            Write-Log "TARGET REACHED AND VALIDATED ($($now.Build)) - OFFSITE COPY WATCH active. Exit 0 withheld until a post-upgrade copy session completes." 'WARN'
            Write-Log 'MANUAL STEP: VSPC/Service Provider Console dependencies cannot be upgraded by cmdlet - no such surface exists in the v13 module. Open the Veeam console AS ADMINISTRATOR on this device and accept the dependency prompt.' 'WARN'
            exit 2
        }
        elseif (Test-Path -LiteralPath $CopyWatchFile) {
            Write-Log "AT $($now.Build) AND VALIDATED (fleet target $(if ($EnablePatch) { $PatchTargetBuild } else { $TargetBuild })). An offsite copy has not yet run since the upgrade - the watch file is retained and a later run will report it, but this device is NOT being held. Cleaning staged media."
            Remove-AllStagedMedia
            Write-Log 'MANUAL STEP: VSPC/Service Provider Console dependencies cannot be upgraded by cmdlet - no such surface exists in the v13 module. Open the Veeam console AS ADMINISTRATOR on this device and accept the dependency prompt.' 'WARN'
            exit 0
        }
        else {
            Write-Log "CONVERGED AT $($now.Build) (fleet target $(if ($EnablePatch) { $PatchTargetBuild } else { $TargetBuild })), validated, offsite copy exercised. Cleaning staged media."
            Remove-AllStagedMedia
            Write-Log 'MANUAL STEP: VSPC/Service Provider Console dependencies cannot be upgraded by cmdlet - no such surface exists in the v13 module. Open the Veeam console AS ADMINISTRATOR on this device and accept the dependency prompt.' 'WARN'
            exit 0
        }
    }

    # =========================================================================
    # PHASE 0.5 - OFFSITE COPY WATCH
    # =========================================================================
    if ((Test-Path -LiteralPath $CopyWatchFile) -and -not (Test-Path -LiteralPath $StateFile)) {
        $watch = Get-Content -LiteralPath $CopyWatchFile -Raw | ConvertFrom-Json
        $nowB = Get-InstalledVbrBuild

        # A device sitting in copy-watch must still be allowed to take a
        # further hop. Copy-watch lives ahead of Stage 1, so without this a box
        # at 13.1.0.411 awaiting a copy could never reach the patch - which is
        # exactly what happened on <SERVER55>. The watch file is left alone;
        # the copy is verified once the box is on its final build.
        if (-not $HoldForCopyWatch) {
            $ageH = 0
            try { $ageH = ((Get-Date).ToUniversalTime() - [datetime]::Parse($watch.sinceUtc).ToUniversalTime()).TotalHours } catch { }
            Write-Log ("Offsite copy watch open since {0} ({1:n1} h) for: {2}. NOT holding - getting this BDR onto the latest build takes priority. The watch file is retained and the copy is still reported." -f `
                $watch.sinceUtc, $ageH, ($watch.jobs -join ', ')) 'WARN'
        }
        elseif ($nowB.Build -ge $TargetBuild) {
            Write-Log "Offsite copy watch active since $($watch.sinceUtc) for: $($watch.jobs -join ', ')."
            Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs
            $live = Get-VeeamLiveState
            if ($null -eq $live -or -not $live.ok) {
                Write-Log "Copy watch: Veeam query failed ($(if($live){$live.error}else{'no output'})). Re-run to retry." 'WARN'
                exit 2
            }
            $bl = Get-Content -LiteralPath $watch.baselineFile -Raw | ConvertFrom-Json
            $watchJobs = @($bl.copyJobs | Where-Object { [string]$_.name -in @($watch.jobs) })
            $cs = Get-PostUpgradeCopyStatus -BaselineCopyJobs $watchJobs -LiveSessions $live.sessions `
                    -SinceUtc ([datetime]::Parse($watch.sinceUtc).ToUniversalTime())

            if ($cs.Failed.Count -gt 0) {
                Write-Log 'OFFSITE COPY FAILED post-upgrade (was healthy at baseline):' 'ERROR'
                foreach ($f in $cs.Failed) { Write-Log "  $f" 'ERROR' }
                exit 2
            }
            $stillWaiting = @($cs.NotYet)
            if ($stillWaiting.Count -eq 0) {
                Write-Log "Offsite copy exercised post-upgrade: $($cs.Succeeded -join ', '). Watch cleared."
                if (-not $PreflightOnly) { Remove-Item -LiteralPath $CopyWatchFile -Force; Remove-AllStagedMedia }
                Write-Log "CONVERGED at $($nowB.Build) (fleet target $(if ($EnablePatch) { $PatchTargetBuild } else { $TargetBuild })), validated, offsite copy verified."
                exit 0
            }
            $ageH = ((Get-Date).ToUniversalTime() - [datetime]::Parse($watch.sinceUtc).ToUniversalTime()).TotalHours
            if ($ageH -ge $CopyWatchHours) {
                Write-Log "OFFSITE COPY has not run in $([math]::Round($ageH,1)) h post-upgrade for: $($stillWaiting -join ', '). Copies are hourly per standard - this is itself a finding." 'ERROR'
                exit 2
            }
            Write-Log "Offsite copy not yet observed for: $($stillWaiting -join ', ') ($([math]::Round($ageH,1)) h of $CopyWatchHours). Re-run after the next hourly copy cycle."
            exit 2
        }
    }

    # =========================================================================
    # STAGE 1 - Detect installed build and select track
    # =========================================================================
    $vbr = Get-InstalledVbrBuild
    $installed = $vbr.Build
    $arpVer = Get-VbrArpVersion
    Write-Log ("Installed build: {0} (file version) | ARP DisplayVersion: {1}" -f $installed, $(if ($arpVer) { $arpVer } else { '<not found>' }))

    # ---- PATCH TRACK -------------------------------------------------------
    # KB4738: the 13.1.1.18 patch "can only be used to patch build
    # 13.1.0.411. If an earlier version is installed, the installer will
    # display: This update is not compatible with installed product version."
    # So it is a THIRD rung, not a new target - a box below 13.1.0.411 must
    # reach it by full ISO first.
    # A patched box can still report the BASE file version. <SERVER04> and
    # <SERVER07> read 13.1.0.411 from Veeam.Backup.Service.exe while software
    # inventory reported 13.1.1.18 - so a file-version-only test routes an
    # already-patched device back to the patch, forever. Trust either source.
    # THE PRODUCT BUILD IS THE ONLY RELIABLE PATCHED / NOT-PATCHED SIGNAL.
    #
    # v4.19 added a second test against "Veeam Updater Plug-in for Veeam
    # Backup & Replication", on the evidence that it read 13.1.1.18 on patched
    # devices and was absent on unpatched ones. That was wrong: the plug-in
    # SHIPS at 13.1.1.18 inside the 13.1.0.411 ISO, so it is a component
    # version, not a record of the patch having run. <SERVER46> is at
    # product build 13.1.0.411 with the plug-in reading 13.1.1.18 and has
    # never been patched; <SERVER47> is equally unpatched with the plug-in
    # reading 13.1.0.411. The signal does not distinguish anything.
    #
    # It silently marked 184 devices "already patched - treating as
    # converged", which is why "Post-upgrade build: 13.1.1.18" stayed at zero
    # for the entire project.
    #
    # The patch DOES move Veeam.Backup.Service.exe's file version to
    # 13.1.1.18, which is exactly what Get-InstalledVbrBuild reads. Trust that
    # and nothing else.
    $prodRaw = Get-VbrProductArpVersion
    $prodV = $null
    if ($prodRaw) { [void][version]::TryParse((($prodRaw -split '\s')[0]), [ref]$prodV) }
    Write-Log ("Product ARP row 'Veeam Backup & Replication': {0}" -f $(if ($prodRaw) { $prodRaw } else { '<not found>' }))
    # The product ARP row is the patch signal. The file version is NOT - the
    # patch leaves Veeam.Backup.Service.exe at the base build, which is why
    # 7 devices were FATAL'd in the 2026-09-23 wave for "not advancing" after
    # patching successfully.
    $alreadyPatched = (($prodV -and $prodV -ge $PatchTargetBuild) -or ($installed -ge $PatchTargetBuild))
    if ($EnablePatch -and $installed -eq $PatchBaseBuild -and -not $alreadyPatched) {
        if ([string]::IsNullOrWhiteSpace($DownloadUrlPatch) -or
            [string]::IsNullOrWhiteSpace($SaveFilePatch) -or
            [string]::IsNullOrWhiteSpace($Sha256Patch)) {
            throw 'enablePatch=1 but downloadUrlPatch / saveFilePatch / sha256Patch are not all set.'
        }
        $track = 'PATCH'; $isoUrl = $DownloadUrlPatch; $isoName = $SaveFilePatch
        $isoHash = $Sha256Patch; $hopTarget = $PatchTargetBuild; $hopMinimum = $PatchTargetBuild
        $emitProactive = $false; $answerSchema = $null
        Write-Log "Track: PATCH  ->  $installed -> $hopTarget (patch ISO, no answer file)"
    }
    elseif ($installed -ge $TargetBuild -or $alreadyPatched) {
        # $TargetBuild is the ISO CEILING, not the end state. Report the real
        # final build so nobody reading an activity log concludes the fleet is
        # finished at the wrong version.
        $finalBuild = if ($EnablePatch) { $PatchTargetBuild } else { $TargetBuild }
        # THE CONVERGED TEST MUST USE THE ARP ROW, NOT THE FILE VERSION.
        # The patch leaves Veeam.Backup.Service.exe at 13.1.0.411 forever, so
        # comparing the file version against 13.1.1.18 is always false on a
        # patched device and it falls through to the "cannot reach by script"
        # message. v4.31 skipped the patch correctly on 185 already-patched
        # devices and then told you it had given up on them.
        # <SERVER07> settled it: patched 2026-09-09 (its
        # VeeamBackupAndReplication13Patch log is still on disk), product ARP
        # row 13.1.1.18, file version 13.1.0.411. Same shape as <SERVER47>
        # patched on 2026-09-23. The ARP row is consistent; an activity feed
        # that only reaches back three days is what made those devices look
        # unpatched.
        if ($installed -ge $finalBuild -or $alreadyPatched) {
            $how = if ($installed -ge $finalBuild) { "build $installed" } else { "product ARP row $prodRaw (the patch does not move the file version, which stays at $installed)" }
            Write-Log "CONVERGED: at the fleet target $finalBuild - $how. Nothing to do."
    $script:StateForField = 'CONVERGED'; $script:StateDetailForField = $how
        }
        elseif ($EnablePatch) {
            Write-Log "At $installed with the product ARP row reading '$prodRaw'. The fleet target is $PatchTargetBuild and the patch applies ONLY to exactly $PatchBaseBuild, so this build cannot be patched by this script." 'WARN'
        }
        else {
            Write-Log "At $installed, at or above the ISO ceiling $TargetBuild. The fleet target is $PatchTargetBuild but enablePatch=0, so the patch stage is off. Treating as converged." 'WARN'
        }

        # A CONVERGED DEVICE STILL NEEDS ITS HOST COMPONENTS CHECKED.
        # This is the single biggest field failure of the project. After the
        # v4.30 patch wave, 70 sites had every Server/VM backup job die in
        # 8-16 seconds with "host rescan is required" or "Server <x> has an
        # outdated Data Mover service version". The patch advances the VBR
        # server past its managed Hyper-V hosts, and until those hosts are
        # upgraded no job can run.
        # The component upgrade only ran after a hop or a validation pass, so
        # every one of those devices logged "CONVERGED - Nothing to do", exited
        # in eight lines, and never looked. Confirmed remediation on
        # <SERVER45>: Get-VBRPhysicalHost showed <HOST01> IsUpToDate=False,
        # Update-VBRServerComponent -Component <host> returned
        # "Host Upgrade ... Result: Success" in 26 seconds, IsUpToDate went
        # True, and the job ran.
        # Invoke-ComponentUpgrade RETURNS a result object and logs nothing
        # itself - the caller has to unpack it. v4.34 called it and discarded
        # the return value, so on <SERVER45> it ran (visible as a silent
        # 17-second gap in that log), found <HOST01> out of date, and reported
        # nothing. Zero of ~70 sites were remediated. Same unpack as the
        # post-validation call site.
        if ($UpgradeComponents) {
            Write-Log '--- Managed component upgrade ---'
            try {
                $cu = Invoke-ComponentUpgrade
                if ($cu) {
                    foreach ($l in @($cu.log)) { if ($l) { Write-Log $l } }
                    if ($cu.skipped) { Write-Log "Component upgrade skipped: $($cu.skipped)" 'WARN' }
                    elseif (-not $cu.ok) { Write-Log "Component upgrade error: $($cu.error)" 'WARN' }
                    elseif (@($cu.upgraded).Count -gt 0) {
                        Write-Log ("HOST COMPONENTS UPGRADED on {0} host(s): {1}. Backup jobs on this device should run again - they fail in seconds while a managed host is out of date." -f `
                            @($cu.upgraded).Count, (@($cu.upgraded) -join ', ')) 'WARN'
                    }
                } else {
                    Write-Log 'Component upgrade returned nothing.' 'WARN'
                }
            } catch { Write-Log "Component upgrade failed: $($_.Exception.Message)" 'WARN' }
            try { Invoke-AgentUpdate } catch { Write-Log "Agent update stage failed: $($_.Exception.Message)" 'WARN' }
        }
        exit 0
    }
    elseif ($installed -ge $GateBuild) {
        $track = 'DIRECT'; $isoUrl = $DownloadUrlV13; $isoName = $SaveFileV13
        $isoHash = $Sha256V13; $hopTarget = $TargetBuild; $hopMinimum = $TargetBuild
        $emitProactive = $true
        $answerSchema = '1.1'   # v13.1 ISO ships AnswerFiles at version="1.1"
    } else {
        $track = 'INTERMEDIATE'; $isoUrl = $DownloadUrlV12; $isoName = $SaveFileV12
        $isoHash = $Sha256V12; $hopTarget = [version]'12.3.2.4465'; $hopMinimum = $GateBuild
        $emitProactive = $false
        $answerSchema = '1.0'   # the 12.3.2 ISO expects version="1.0"
    }
    $fleetTarget = if ($EnablePatch) { $PatchTargetBuild } else { $TargetBuild }
    $hopsLeft = 0
    if ($installed -lt $GateBuild) { $hopsLeft = 2 } elseif ($installed -lt $TargetBuild) { $hopsLeft = 1 }
    if ($EnablePatch -and $installed -lt $PatchTargetBuild) { $hopsLeft++ }
    Write-Log "Track: $track  ->  this hop goes to $hopTarget (minimum acceptable: $hopMinimum). Fleet target is $fleetTarget - approximately $hopsLeft hop(s) remaining for this device."

    if ([string]::IsNullOrWhiteSpace($isoUrl) -or [string]::IsNullOrWhiteSpace($isoName) -or [string]::IsNullOrWhiteSpace($isoHash)) {
        throw "Missing RMM variables for track $track (url / filename / sha256)."
    }

    $script:IsoFolder = Resolve-StagingFolder
    $stagingDrive = $script:IsoFolder.Substring(0,2)
    $isoPath   = Join-Path $script:IsoFolder $isoName
    $srcFolder = Join-Path $script:IsoFolder ('src_' + [IO.Path]::GetFileNameWithoutExtension($isoName))

    # =========================================================================
    # STAGE 2 - Preflight gates
    # =========================================================================
    Write-Log '--- Preflight ---'

    # POWERSHELL 7 THAT EXISTS BUT CANNOT START.
    # <SERVER25>: every Veeam query died because PowerShell 7 was missing
    # System.Private.CoreLib.dll - its own runtime, not Veeam's. A repair from
    # its cached installer put every file back by hand; this does the same,
    # once per run, before Veeam is queried.
    if ($pwLoc -and -not $PreflightOnly) {
        $pwOk = $false
        try { $pwOut = & $pwLoc -NoProfile -NonInteractive -Command 'Write-Output pwsh-ok' 2>&1; $pwOk = (@($pwOut) -contains 'pwsh-ok') } catch { }
        if (-not $pwOk) {
            Write-Log "pwsh.exe exists at $pwLoc but cannot start - its runtime files are damaged." 'WARN'
            if (Repair-Pwsh7) { $pwLoc = Get-PwshPath }
        }
    }

    # Repository paths are needed before pruning, so query Veeam first.
    $pf = $null
    try { $pf = Get-VeeamPreflightState } catch { Add-Gate 'VeeamPowerShell' $false "Veeam query failed: $($_.Exception.Message)" }
    $repoPaths = @()
    if ($pf -and $pf.repoPaths) { $repoPaths = @($pf.repoPaths) }

    if (-not $PreflightOnly) {
        Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs
        Remove-StaleInstallMedia -KeepIsoName $isoName -KeepSrcFolder $srcFolder
        Remove-OldVeeamLogs -RetentionDays $VeeamLogRetentionDays -RepoPaths $repoPaths
    }
    $isoStaged = Test-Path -LiteralPath $isoPath

    $pgSvc  = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'postgresql*' } | Select-Object -First 1
    $sqlSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'MSSQL$*' } | Select-Object -First 1
    if ($pgSvc)      { Write-Log "DB engine: PostgreSQL ($($pgSvc.Name)) - not upgraded, not stopped by this script." }
    elseif ($sqlSvc) { Write-Log "DB engine: MSSQL ($($sqlSvc.Name)) - not upgraded, not stopped by this script." }
    else             { Write-Log 'DB engine: no local postgresql*/MSSQL$* service found (remote or unknown).' 'WARN' }

    # PENDING FILE RENAMES COUNT TOO - BUT ONLY ONCE.
    # This gate used to read only the Windows Update and servicing-stack flags.
    # <SERVER27>, <SERVER28> and <SERVER29> passed it, then setup refused with
    # event 013 "reboot required". Files queued for replacement at next boot
    # are what installers actually check. Some software leaves a rename that
    # never clears, so a rename-only pending reboot is acted on ONCE: if this
    # script already rebooted for it and the box has booted since, it is
    # logged for a person instead of rebooting every run.
    $prWU  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $prCBS = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $prFR  = $false
    try { $prFR = @((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations | Where-Object { $_ }).Count -gt 0 } catch { }
    if (-not $prFR) { Clear-RebootMarker -Name 'pending-renames' }
    elseif (-not ($prWU -or $prCBS)) {
        $mk = Get-RebootMarker -Name 'pending-renames'
        if ($mk -and $mk.rebootedSince) {
            Write-Log ("Pending file renames are still queued after this script's reboot for them at {0}. Treating them as sticky and not gating on them. If setup refuses with 'reboot required', a person should look at what keeps queueing renames." -f $mk.rebootedUtc) 'WARN'
            $prFR = $false
        }
    }
    $pendingReboot = $prWU -or $prCBS -or $prFR
    $pendingWhy = @(); if ($prWU) { $pendingWhy += 'Windows Update' }; if ($prCBS) { $pendingWhy += 'servicing stack' }; if ($prFR) { $pendingWhy += 'pending file renames' }
    Add-Gate 'PendingReboot' (-not $pendingReboot) $(if ($pendingReboot) { 'Reboot pending: ' + ($pendingWhy -join ', ') } else { 'Clear' })

    $minFree = if ($isoStaged) { $MinFreeGBStaged } else { $MinFreeGBUnstaged }
    $stagingVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$stagingDrive'" -ErrorAction SilentlyContinue
    $freeGB  = if ($stagingVol) { [math]::Round($stagingVol.FreeSpace / 1GB, 1) } else { 0 }
    Add-Gate 'FreeSpace' ($freeGB -ge $minFree) "$freeGB GB free on $stagingDrive (need $minFree GB; ISO staged: $isoStaged)"

    # Veeam setup needs space on C: for MSI extraction and component installs
    # no matter where the ISO is staged (event id=105, <SERVER05> and <SERVER07>).
    # A FULL HOP NEEDS MORE THAN A PATCH. Setup asked for exactly 32.27 GB on
    # <SERVER03> and <SERVER20>, so the old 30 GB floor let both pass here and
    # then fail at the install - after their jobs had already been paused.
    # The patch track keeps 30 GB: there is no evidence it needs more, and
    # raising it would strand tight boxes between their hop and their patch.
    $sysGate = if ($track -eq 'PATCH') { $MinFreeGBSystem } else { $MinFreeGBSystemHop }
    $sysVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    $sysFreeGB = if ($sysVol) { [math]::Round($sysVol.FreeSpace / 1GB, 1) } else { 0 }
    if ($sysFreeGB -lt $sysGate -and $DeepDiskClean -and -not $PreflightOnly) {
        try { $sysFreeGB = Invoke-DeepDiskClean -NeedGB $sysGate -RepoPaths $repoPaths } catch { Write-Log "Deep disk clean failed: $($_.Exception.Message)" 'WARN' }
    }
    Add-Gate 'SystemDriveFreeSpace' ($sysFreeGB -ge $sysGate) "$sysFreeGB GB free on C: (a $track run needs $sysGate GB there regardless of staging volume)"

    # v13 installs its own web service which legitimately binds 443 - only a
    # NON-Veeam listener is a genuine conflict (fleet: 17 halts became 0).
    $o443 = Get-PortOwner -Port 443
    $any443 = Test-PortListening -Port 443
    $veeam443 = ($o443 -and $o443 -match '(?i)veeam')
    Add-Gate 'Port443' ((-not $any443) -or $veeam443) $(
        if (-not $any443)  { 'Free' }
        elseif ($veeam443) { "Bound by $o443 (Veeam's own service - not a conflict)" }
        else               { "Bound by $(if ($o443) { $o443 } else { 'an unidentified process' })" })

    # CLOSE IT, DO NOT HALT ON IT.
    # Veeam.Backup.Shell is the console UI. An open console blocks setup, but
    # it is not a site fault - it is somebody who left a window open, and 8-9
    # devices sat on this gate in every wave of the 2026-09-23 project.
    # Closing it costs an unsaved console session and nothing else: no backup
    # job, no service, no data.
    $console = @(Get-Process -Name 'Veeam.Backup.Shell' -ErrorAction SilentlyContinue)
    if ($console.Count -gt 0 -and $CloseConsole) {
        $who = @()
        foreach ($c in $console) {
            try {
                $o = (Get-CimInstance Win32_Process -Filter "ProcessId=$($c.Id)" -ErrorAction SilentlyContinue).GetOwner()
                if ($o -and $o.User) { $who += "$($o.Domain)\$($o.User)" }
            } catch { }
        }
        Write-Log ("Veeam console open ({0} process(es){1}) - closing it so the upgrade can proceed. Any unsaved console session is lost; nothing else is affected." -f `
            $console.Count, $(if ($who.Count) { ' owned by ' + (($who | Select-Object -Unique) -join ', ') } else { '' })) 'WARN'
        foreach ($c in $console) { try { $c.CloseMainWindow() | Out-Null } catch { } }
        Start-Sleep -Seconds 10
        $console = @(Get-Process -Name 'Veeam.Backup.Shell' -ErrorAction SilentlyContinue)
        if ($console.Count -gt 0) {
            foreach ($c in $console) { try { Stop-Process -Id $c.Id -Force -ErrorAction SilentlyContinue } catch { } }
            Start-Sleep -Seconds 5
            $console = @(Get-Process -Name 'Veeam.Backup.Shell' -ErrorAction SilentlyContinue)
        }
        if ($console.Count -eq 0) { Write-Log 'Veeam console closed.' }
        else { Write-Log ("Veeam console would not close ({0} still running)." -f $console.Count) 'ERROR' }
    }
    Add-Gate 'ConsoleClosed' ($console.Count -eq 0) $(if ($console.Count -gt 0) { 'Console open' } else { 'Closed' })

    # SET IT, DO NOT JUST GATE ON IT.
    # This value is a prerequisite of THIS SCRIPT'S OWN install method - the
    # installer runs as a local admin through a scheduled task, and without
    # LocalAccountTokenFilterPolicy=1 UAC hands that account a filtered token.
    # It is not a site condition and not something a tech configured wrongly;
    # it is simply absent by default on a workgroup BDR. Halting on it blocked
    # <SERVER47> for three consecutive runs with all 16 other gates green
    # and the patch track correctly selected.
    $latfpPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $latfp = (Get-ItemProperty $latfpPath -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    if ($latfp -ne 1) {
        $was = $(if ($null -eq $latfp) { '<absent>' } else { $latfp })
        try {
            if (-not (Test-Path -LiteralPath $latfpPath)) { New-Item -Path $latfpPath -Force | Out-Null }
            New-ItemProperty -Path $latfpPath -Name LocalAccountTokenFilterPolicy `
                -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
            $latfp = (Get-ItemProperty $latfpPath -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
            if ($latfp -eq 1) {
                Write-Log "LocalAccountTokenFilterPolicy was $was - set to 1 (required for the installer's scheduled-task logon; no reboot needed)." 'WARN'
            } else {
                Write-Log "LocalAccountTokenFilterPolicy was $was and did not take the new value - it may be enforced by Group Policy." 'ERROR'
            }
        } catch {
            Write-Log "Could not set LocalAccountTokenFilterPolicy: $($_.Exception.Message). If this is Group Policy managed it needs changing there." 'ERROR'
        }
    }
    Add-Gate 'LocalAccountTokenFilterPolicy' ($latfp -eq 1) "Value=$(if ($null -eq $latfp) { '<absent>' } else { $latfp }) (expected 1)"

    $svcAcct = (Get-CimInstance Win32_Service -Filter "Name='VeeamBackupSvc'" -ErrorAction SilentlyContinue).StartName
    Add-Gate 'ServiceAccount' ($svcAcct -in @('LocalSystem','NT AUTHORITY\SYSTEM')) "Runs as '$svcAcct'"

    $vbsStatus = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
    if ($vbsStatus -eq 'Running') { Clear-RebootMarker -Name 'svc-stoppending' }
    Add-Gate 'BackupServiceRunning' ($vbsStatus -eq 'Running') "VeeamBackupSvc=$vbsStatus"

    $listening9392 = Test-PortListening -Port 9392
    Add-Gate 'BackupServiceListening' $listening9392 $(if ($listening9392) { 'Listening on 9392' } else { 'Nothing listening on 9392 - service up but not serving' })

    $pwVer = $null
    if ($pwLoc) { try { $pwVer = (& $pwLoc -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null) } catch { } }
    Add-Gate 'Ps7Available' ([bool]$pwLoc) $(if ($pwLoc) { "pwsh $pwVer" } else { 'pwsh.exe NOT FOUND - required for the Veeam v13 PowerShell module.' })

    $adminOk = $false; $adminDetail = ''
    try {
        $u = Get-LocalUser -Name $InstallAdminUser -ErrorAction Stop
        $inAdmins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*\$InstallAdminUser" }).Count -gt 0
        $adminOk = ($u.Enabled -and $inAdmins)
        $adminDetail = "Enabled=$($u.Enabled) InAdministrators=$inAdmins"
    } catch { $adminDetail = "Account '$InstallAdminUser' not found: $($_.Exception.Message)" }
    Add-Gate 'InstallAdminAccount' $adminOk $adminDetail

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $mgmt = @(Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^Veeam Backup Enterprise Manager|^Veeam ONE' } |
        Select-Object -ExpandProperty DisplayName -Unique)
    Add-Gate 'NoCoResidentMgmt' ($mgmt.Count -eq 0) $(if ($mgmt.Count) { ($mgmt -join '; ') + ' present - must be upgraded before VBR' } else { 'None detected' })

    if ($pf -and $pf.ok) {
        if ($null -ne $pf.workingSessions) {
            # With pausing enabled this is NOT a halt: the script disables the
            # schedules and waits for the session to drain at Stage 5.5. A
            # preflight-time check was useless anyway - 20-40 minutes of
            # download separate it from the install.
            if ([int]$pf.workingSessions -eq 0) {
                Add-Gate 'NoActiveSessions' $true '0 session(s) working'
            } elseif ($PauseJobs) {
                Add-Gate 'NoActiveSessions' $true "$($pf.workingSessions) session(s) working ($($pf.workingJobNames)) - will wait for them before installing"
            } else {
                Add-Gate 'NoActiveSessions' $false "$($pf.workingSessions) session(s) working ($($pf.workingJobNames)) - re-run outside the job window (pauseJobsDuringUpgrade=0)"
            }
        } else {
            # Could not evaluate is NOT the same as failed. Blocking an upgrade
            # because a query errored halted <SERVER31> on four gates while
            # the box was entirely healthy.
            Write-Log "NoActiveSessions could not be evaluated: $($pf.workingSessionsError). Not treating that as a gate failure." 'WARN'
            Add-Gate 'NoActiveSessions' $true "not evaluated ($($pf.workingSessionsError))"
        }

        if ($null -ne $pf.legacyChain) { Add-Gate 'LegacyChainFormat' ([int]$pf.legacyChain -eq 0) "$($pf.legacyChain) legacy-format backup(s) of $($pf.backupCount)" }
        else {
            Write-Log "LegacyChainFormat could not be evaluated: $($pf.legacyChainError). Not treating that as a gate failure." 'WARN'
            Add-Gate 'LegacyChainFormat' $true "not evaluated ($($pf.legacyChainError))"
        }

        if ($null -ne $pf.legacyCopyJobs) { Add-Gate 'LegacyBackupCopyJob' ([int]$pf.legacyCopyJobs -eq 0) "$($pf.legacyCopyJobs) legacy copy job(s)" }
        else {
            Write-Log "LegacyBackupCopyJob could not be evaluated: $($pf.legacyCopyJobsError). Not treating that as a gate failure." 'WARN'
            Add-Gate 'LegacyBackupCopyJob' $true "not evaluated ($($pf.legacyCopyJobsError))"
        }

        if ($null -ne $pf.hardenedRepos) { Add-Gate 'NoHardenedRepo' ([int]$pf.hardenedRepos -eq 0) "$($pf.hardenedRepos) hardened repo(s)" }
        else {
            Write-Log "NoHardenedRepo could not be evaluated: $($pf.hardenedReposError). Not treating that as a gate failure." 'WARN'
            Add-Gate 'NoHardenedRepo' $true "not evaluated ($($pf.hardenedReposError))"
        }

        Write-Log "OFFSITE: $($pf.objectRepoCount) object storage repo(s), $($pf.copyJobCount) copy job(s). Configuration backup: not evaluated (separate workstream)."
    } elseif ($pf) {
        Add-Gate 'VeeamPowerShell' $false "Veeam preflight query error: $($pf.error)"
    }

    # --- Report ---
    # PASSING GATES DO NOT NEED A LINE EACH.
    # Seventeen gates at one line apiece is ~1,500 characters of a 10,003
    # character budget spent saying nothing happened. Failures get their full
    # detail; passes get their names on one line, and the few whose VALUES are
    # worth having regardless (disk space) keep theirs.
    $failed = @($gates | Where-Object { -not $_.Pass })
    $passed = @($gates | Where-Object { $_.Pass })
    Write-Log '--- Gate results ---'
    foreach ($g in $failed) { Write-Log ("{0,-32} {1,-6} {2}" -f $g.Gate, 'FAIL', $g.Detail) }
    foreach ($g in @($passed | Where-Object { $_.Gate -in @('FreeSpace','SystemDriveFreeSpace') })) {
        Write-Log ("{0,-32} {1,-6} {2}" -f $g.Gate, 'PASS', $g.Detail)
    }
    $quiet = @($passed | Where-Object { $_.Gate -notin @('FreeSpace','SystemDriveFreeSpace') } | ForEach-Object { $_.Gate })
    if ($quiet.Count -gt 0) { Write-Log ("PASS ({0}): {1}" -f $quiet.Count, ($quiet -join ', ')) }

    if ($PreflightOnly) {
        Write-Log '--- Agent inventory (report only) ---'
        [void](Invoke-AgentRemediation -StaleDays $StaleAgentDays -RestorePointDays $StaleRestorePointDays -ReportOnly $true)
        Write-Log "PREFLIGHT-ONLY complete. $($failed.Count) gate(s) failed. No changes made."
        Write-Log 'NOTE: preflight-only skips disk reclamation, so FreeSpace reflects the uncleaned volume.' 'WARN'
        exit $(if ($failed.Count -gt 0) { 2 } else { 0 })
    }

    if ($failed.Count -gt 0) {
        Write-Log "HALTED - $($failed.Count) preflight gate(s) failed. Upgrade NOT attempted." 'ERROR'
        foreach ($g in $failed) { Write-Log ("  BLOCKED BY: {0} - {1}" -f $g.Gate, $g.Detail) 'ERROR' }
        $script:StateForField = 'GATE_HALT'
        $script:StateDetailForField = (($failed | ForEach-Object { "$($_.Gate): $($_.Detail)" }) -join '; ')
        # ONE REBOOT, HOWEVER MANY REASONS. Asking twice in one run made the
        # second shutdown.exe fail ("already scheduled"), and Invoke-ForcedReboot
        # answers a failed request with Restart-Computer -Force - an immediate
        # reboot that skips the delay and cuts the log off. One reboot clears a
        # pending reboot and a stuck service alike; each reason still gets its
        # once-only marker.
        $rebootFor = $null
        if ($pendingReboot) {
            if ($prFR -and -not ($prWU -or $prCBS)) { Set-RebootMarker -Name 'pending-renames' }
            $rebootFor = 'clearing pending reboot so the next run proceeds'
        }
        # A VeeamBackupSvc already stuck in StopPending BEFORE this run touched
        # anything is a wedge left over from an earlier stop (<SERVER29>).
        # No jobs are paused yet, so a reboot is safe here - once. If it is
        # stuck again after this script's reboot for it, a person looks.
        if ($vbsStatus -eq 'StopPending') {
            $mk = Get-RebootMarker -Name 'svc-stoppending'
            if ($mk -and $mk.rebootedSince) {
                Write-Log ("VeeamBackupSvc is stuck in StopPending again after this script's reboot for it at {0}. Not rebooting a second time - THIS DEVICE NEEDS A PERSON to find what keeps wedging the service." -f $mk.rebootedUtc) 'ERROR'
            } else {
                Set-RebootMarker -Name 'svc-stoppending'
                if (-not $rebootFor) { $rebootFor = 'clearing a VeeamBackupSvc stuck in StopPending before the upgrade' }
            }
        }
        if ($rebootFor) { Invoke-ForcedReboot -Reason $rebootFor }
        exit 2
    }
    Write-Log 'All preflight gates passed.'

    # =========================================================================
    # STAGE 2.6 - Retrieve AND VALIDATE install credential
    # =========================================================================
    Write-Log "Retrieving install credential from device field '$LapsFieldName' ..."
    $AdminPassword = Get-NinjaSecureField -FieldName $LapsFieldName
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        throw "Could not retrieve '$LapsFieldName' from this device's custom fields. If the field exists, its Scripts permission must allow Read. The installer cannot run without the local admin credential (SYSTEM is refused by the Veeam setup engine)."
    }
    if (-not (Test-LocalCredential -User $InstallAdminUser -Password $AdminPassword)) {
        $AdminPassword = $null
        throw "The '$LapsFieldName' value does NOT authenticate for $env:COMPUTERNAME\$InstallAdminUser. LAPS has almost certainly rotated without the custom field being updated - the same fault as <SERVER18> (Security 4625, substatus 0xC000006A) and <SERVER58>. Nothing was changed and no download was started."
    }
    Write-Log "Credential retrieved and validated for .\$InstallAdminUser (value not logged)."

    # =========================================================================
    # STAGE 2.7 - Agent blocker remediation
    # =========================================================================
    Write-Log '--- Agent remediation ---'
    $agentPre = Invoke-AgentRemediation -StaleDays $StaleAgentDays -RestorePointDays $StaleRestorePointDays
    if ($agentPre.Blocked.Count -gt 0) {
        Write-Log 'Agent(s) require a human decision - not auto-remediated:' 'WARN'
        foreach ($b in $agentPre.Blocked) { Write-Log "  $b" 'WARN' }
    }

    # =========================================================================
    # STAGE 2.5 - Baseline snapshot
    # =========================================================================
    Write-Log 'Capturing pre-upgrade baseline ...'
    $liveNow = Get-VeeamLiveState
    if ($null -eq $liveNow -or -not $liveNow.ok) {
        throw "Baseline capture failed: $(if($liveNow){$liveNow.error}else{'no output from the Veeam query'}). Proceeding without a baseline defeats post-upgrade validation."
    }
    $baseline = [ordered]@{
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
        fromBuild   = [string]$installed
        services    = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue | ForEach-Object {
                          [ordered]@{ name = [string]$_.Name; startType = [string]$_.StartType; status = [string]$_.Status } })
        jobs        = @($liveNow.jobs)
        repos       = @($liveNow.repos)
        objectRepos = @($liveNow.objectRepos)
        s3CredCount = [int]$liveNow.s3CredCount
        copyJobs    = @($liveNow.copyJobs)
        backups     = @($liveNow.backups)
    }
    $baseline | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BaselineFile -Encoding UTF8 -Force
    Write-Log ("Baseline: {0} service(s), {1} job(s), {2} repo(s), {3} object repo(s), {4} S3 cred(s), {5} copy job(s), {6} backup object(s)" -f `
        @($baseline.services).Count, @($baseline.jobs).Count, @($baseline.repos).Count, @($baseline.objectRepos).Count,
        $baseline.s3CredCount, @($baseline.copyJobs).Count, @($baseline.backups).Count)

    # =========================================================================
    # STAGE 3 - Stage and verify ISO
    # =========================================================================
    if (-not (Test-Path -LiteralPath $script:IsoFolder)) { New-Item -Path $script:IsoFolder -ItemType Directory -Force | Out-Null }

    if (-not $isoStaged) { Write-Log "Downloading $isoName to $($script:IsoFolder) ..."; Invoke-IsoDownload -Url $isoUrl -Destination $isoPath }
    else { Write-Log "ISO already staged: $isoPath" }

    Write-Log 'Verifying SHA256 (several minutes on an 18 GB file) ...'
    if (-not (Test-IsoHash -Path $isoPath -Expected $isoHash)) {
        Write-Log 'SHA256 mismatch. Deleting and re-downloading once.' 'WARN'
        Remove-Item -LiteralPath $isoPath -Force
        Invoke-IsoDownload -Url $isoUrl -Destination $isoPath
        if (-not (Test-IsoHash -Path $isoPath -Expected $isoHash)) {
            Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
            throw "SHA256 mismatch after re-download. Expected $isoHash. Corrupt ISO deleted. NOTE: if the source is Veeam's CDN, an auth redirect (HTML instead of ISO) produces exactly this symptom."
        }
    }
    Write-Log 'SHA256 verified.'
    Unblock-File -LiteralPath $isoPath -ErrorAction SilentlyContinue

    # =========================================================================
    # STAGE 4 - Copy install source to writable local disk
    # =========================================================================
    if ($track -eq 'PATCH') {
        # The patch ISO carries only Setup.exe, autorun.inf and a Setup folder -
        # there is no Setup\Silent\Veeam.Silent.Install.exe and no AnswerFiles.
        $exe = Expand-IsoToLocal -IsoPath $isoPath -Destination $srcFolder -InstallerRelativePath 'Setup.exe'
    } else {
        $exe = Expand-IsoToLocal -IsoPath $isoPath -Destination $srcFolder
    }
    Write-Log ("Setup engine: {0}" -f (Get-Item -LiteralPath $exe).VersionInfo.FileVersion)

    # =========================================================================
    # STAGE 5 - Answer file
    # =========================================================================
    $answerFile = $null
    if ($track -eq 'PATCH') {
        Write-Log "Patch track - no answer file. Setup.exe will be run with: $PatchArgs"
    } else {
    $proactive = if ($emitProactive) { "`r`n        <property name=`"VBR_PROACTIVE_SUPPORT`" value=`"0`" />" } else { '' }
    $answerXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattendedInstallationConfiguration bundle="Vbr" mode="upgrade" version="$answerSchema">
    <properties>
        <property name="ACCEPT_EULA" value="1" />
        <property name="ACCEPT_LICENSING_POLICY" value="1" />
        <property name="ACCEPT_THIRDPARTY_LICENSES" value="1" />
        <property name="ACCEPT_REQUIRED_SOFTWARE" value="1" />
        <property name="VBR_LICENSE_AUTOUPDATE" value="1" />$proactive
        <property name="VBR_ENTRAID_DATABASE_INSTALL" value="0" />
        <property name="VBR_AUTO_UPGRADE" value="$AutoUpgrade" />
        <property name="REBOOT_IF_REQUIRED" value="0" />
    </properties>
</unattendedInstallationConfiguration>
"@
    $answerFile = Join-Path $LogFolder 'VbrAnswerFile_upgrade.xml'
    Set-Content -LiteralPath $answerFile -Value $answerXml -Encoding UTF8 -Force
    Write-Log "Answer file written (schema version=$answerSchema, VBR_AUTO_UPGRADE=$AutoUpgrade, REBOOT_IF_REQUIRED=0)."
    }

    # =========================================================================
    # STAGE 5.5 / 6 - Stop services and install
    # =========================================================================
    $code = -1; $upgradeStartUtc = $null; $attempt = 0; $partialSuccess = $false
    while ($attempt -lt $MaxInstallAttempts) {
        $attempt++
        Remove-Item -LiteralPath $DbReportFile -Force -ErrorAction SilentlyContinue

        # Pause schedules and drain running sessions HERE, not at preflight -
        # the download sits between the two and Veeam's scheduler does not care
        # what a gate decided 40 minutes ago.
        if (-not (Suspend-VeeamJobs)) {
            Write-Log 'Could not reach a quiet state for the install. Nothing on this box was changed; re-run later.' 'ERROR'
            $exitCode = 2
            exit $exitCode
        }

        # THE PATCH TRACK DOES NOT PRE-STOP SERVICES.
        # A full-ISO upgrade must: Veeam setup restarts VeeamBackupSvc to
        # analyse the config DB, allows itself only 300 s for the stop, and
        # rolls back with event id=113 if the service is still draining. So the
        # script stops it first, with a longer budget.
        # A hotfix is a different installer. Veeam's KB says run it elevated
        # and says nothing about stopping services - it manages its own. And
        # 13.1.x carries 32 auto-start Veeam services where 13.0.x had 26, so
        # the pre-stop that worked on 12.x and 13.0.2.29 times out here: in the
        # 2026-09-23 wave 52 devices took the patch track, 48 announced
        # /silent, and ALL 48 died at the 900 s stop after 16-19 minutes
        # without Setup.exe ever being invoked. Zero reached an installer exit
        # code. The stop was the wall, not the patch.
        $skipStop = ($track -eq 'PATCH' -and -not $StopSvcForPatch)
        $spcOriginalStartMode = $null
        if ($skipStop) {
            Write-Log 'PATCH track - NOT pre-stopping Veeam services. The hotfix installer manages its own services, and the pre-stop is what blocked every patch attempt in the 2026-09-23 wave. Set stopServicesForPatch=1 to restore it.' 'WARN'
            # ...but the ONE service that must pause is the SPC agent, which locks
            # Veeam files mid-patch (<SERVER19>). Restored in the finally.
            $spcOriginalStartMode = Suspend-SpcManagementAgent
        }
        elseif (-not (Stop-VeeamForUpgrade -TimeoutSeconds $SvcStopTimeoutSecs)) {
            Write-Log 'Graceful stop did not complete, so the upgrade will not be forced through. Nothing else on this box was changed.' 'WARN'
            # If it is wedged mid-shutdown with nothing left to drain, bring it
            # back so the jobs this run paused can actually be restored.
            if (Reset-WedgedBackupService) {
                try { Restore-PausedJobsFromMemory } catch { Write-Log "Memory restore after reset failed: $($_.Exception.Message)" 'ERROR' }
                try { Restore-VeeamJobs } catch { Write-Log "Job restore after reset failed: $($_.Exception.Message)" 'ERROR' }
            }

            # Jobs are restored AND verified inside Invoke-ForcedReboot before this
            # clean-boot retry - and it refuses to reboot if they cannot be
            # confirmed. The check that stood here in v4.48 failed open.

            # A clean boot only helps once. <SERVER56> killed STARTINFRARESCAN
            # nine times in ten minutes and it respawned every 60-70 s; a reboot
            # does not change that. Without this check the device burns a reboot
            # every scheduled run forever - 120 devices did exactly that in the
            # 2026-09-22 wave.
            $priorStop = $null
            if (Test-Path -LiteralPath $StopRetryFile) {
                try { $priorStop = Get-Content -LiteralPath $StopRetryFile -Raw | ConvertFrom-Json } catch { }
            }
            $bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
            $rebootedSince = $false
            if ($priorStop -and $priorStop.rebootedUtc) {
                try { $rebootedSince = ($bootUtc -gt [datetime]::Parse($priorStop.rebootedUtc).ToUniversalTime()) } catch { }
            }
            if ($priorStop -and $rebootedSince) {
                Write-Log ("THIS DEVICE NEEDS A PERSON. A clean-boot retry was already done at {0}, the box HAS rebooted since (boot {1}), and VeeamBackupSvc still will not stop. Rebooting again would loop forever. A maintenance worker is respawning faster than it can be cleared - investigate what keeps starting it (STARTINFRARESCAN is the usual one) before this device can upgrade." -f `
                    $priorStop.rebootedUtc, $bootUtc.ToString('o')) 'ERROR'
                exit 2
            }
            try {
                [pscustomobject]@{ rebootedUtc = (Get-Date).ToUniversalTime().ToString('o')
                                   bootUtc     = $bootUtc.ToString('o') } |
                    ConvertTo-Json | Set-Content -LiteralPath $StopRetryFile -Encoding UTF8 -Force
            } catch { }
            Invoke-ForcedReboot -Reason 'clean-boot retry before install'
            exit 2
        }
        # stop succeeded - clear any previous retry marker
        Remove-Item -LiteralPath $StopRetryFile -Force -ErrorAction SilentlyContinue

        $upgradeStartUtc = (Get-Date).ToUniversalTime().ToString('o')
        # RE-FETCH THE CREDENTIAL IMMEDIATELY BEFORE USING IT.
        # LAPS ROTATES. The value validated at Stage 2.6 is 20-40 minutes old
        # by the time we get here - the ISO download, hash and extract all sit
        # in between - and a rotation inside that window leaves us registering
        # a scheduled task with a password Windows will reject. That is the
        # "Installer task never entered Running ... LastTaskResult 1603"
        # signature, and it went from 1 device to 13 in the 2026-09-23 wave
        # purely because more devices reached the installer at all.
        $fresh = Get-NinjaSecureField -FieldName $LapsFieldName
        if (-not [string]::IsNullOrWhiteSpace($fresh) -and $fresh -ne $AdminPassword) {
            if (Test-LocalCredential -User $InstallAdminUser -Password $fresh) {
                Write-Log "The '$LapsFieldName' value changed since preflight - LAPS rotated during the download. Using the current value." 'WARN'
                $AdminPassword = $fresh
            } else {
                Write-Log "The '$LapsFieldName' value changed since preflight but the new value does not authenticate either. Keeping the one validated at preflight." 'WARN'
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($fresh)) {
            # Unchanged, but re-validate: it may have rotated and been written
            # back to the field by the time we read it, or rotated without the
            # field updating at all.
            if (-not (Test-LocalCredential -User $InstallAdminUser -Password $AdminPassword)) {
                $AdminPassword = $null
                throw "The '$LapsFieldName' value no longer authenticates for $env:COMPUTERNAME\$InstallAdminUser - LAPS rotated during the $((New-TimeSpan -Start ([datetime]::Parse($upgradeStartUtc)) -End (Get-Date).ToUniversalTime()).TotalMinutes.ToString('n0'))-minute download window and the custom field has not caught up. Re-run once the field refreshes. Nothing was changed."
            }
        }
        Write-Log "Starting upgrade to $hopTarget as $env:COMPUTERNAME\$InstallAdminUser (attempt $attempt of $MaxInstallAttempts). This will take a while."
        $patchArgSpec = $null
        if ($track -eq 'PATCH') {
            $patchArgSpec = (($PatchArgs -split '\s+' | Where-Object { $_ } | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ', ')
        }
        $code = [int](Invoke-InstallerAsLocalAdmin -InstallerExe $exe -AnswerFile $answerFile `
            -InstallLogFolder $LogFolder -User $InstallAdminUser -PlainPassword $AdminPassword -ArgList $patchArgSpec)
        Write-Log "Installer exit code: $code"
        if ($spcOriginalStartMode) { Restore-SpcManagementAgent -OriginalStartMode $spcOriginalStartMode; $spcOriginalStartMode = $null }

        # OUTCOME BEFORE DIAGNOSTICS - THIS LINE MUST SURVIVE THE FEED CAP.
        # NinjaOne truncates activity output at 10,003 characters. The setup
        # log and installer XML dumps that follow are the longest thing a run
        # produces, and they are produced by exactly the runs that SUCCEEDED -
        # so "Post-upgrade build:" and "HOP COMPLETE", written at the very end,
        # were being cut off on every device that actually hopped.
        # <SERVER35> patched cleanly to 13.1.1.18 at 00:26:43Z and three
        # consecutive fleet polls reported zero hops, because its record ended
        # mid-word at 10,003 characters with 33 seconds of the run still to go.
        # One compact line, emitted here, carries the whole outcome and cannot
        # be pushed off the end by anything below it.
        $rBuild = $null; $rArp = $null
        # Get-InstalledVbrBuild returns an OBJECT carrying .Build, not a
        # version - .ToString() on the wrapper renders
        # "System.Collections.Hashtable", which is what the RESULT line showed
        # on <SERVER59> and <SERVER60>.
        try { $rBuild = ([string](Get-InstalledVbrBuild).Build) } catch { $rBuild = 'unreadable' }
        try { $rArp = Get-VbrProductArpVersion } catch { }
        Write-Log ("RESULT: track={0} exit={1} from={2} to={3} build={4} arp={5} attempt={6}" -f `
            $track, $code, $installed, $hopTarget, $rBuild,
            $(if ($rArp) { $rArp } else { '<none>' }), $attempt)

        # DIAGNOSTIC DUMPS ONLY WHEN THERE IS SOMETHING TO DIAGNOSE.
        # The setup log and installer XML are 4-7 thousand characters and are
        # produced by every SUCCESSFUL install - which is how a clean run ended
        # up truncated while a failed one fitted comfortably. On exit 0 or 3010
        # there is nothing in them anyone reads; the RESULT line above already
        # carries the outcome. On any other code they are the only thing that
        # explains the failure, so they print in full.
        if ($code -eq 0 -or $code -eq 3010) {
            Write-Log "Installer completed (exit $code) - setup log dump skipped. Full logs remain in $SetupTempFolder if needed."
        } else {
            # A FAILURE DUMP MUST NOT COST US THE REST OF THE RUN.
            # v4.42 skipped dumps on 0/3010 only, so a 1603 still printed
            # everything and blew past NinjaOne's 10,003-character cap - which
            # hid the agent remediation and retry that follow. Six devices went
            # dark that way on the 2026-09-25 wave and the question "is the
            # script fixing this?" became unanswerable from the feed.
            # The setup report's own error entries are what explain a failure;
            # the assembly-loading chatter around them is not.
            $rpt = $null
            try { if (Test-Path -LiteralPath $DbReportFile) { $rpt = [xml](Get-Content -LiteralPath $DbReportFile -Raw -ErrorAction Stop) } } catch { }
            if ($rpt) {
                foreach ($iss in @($rpt.report.issue | Where-Object { $_.severity -eq 'error' })) {
                    Write-Log ("SETUP ERROR: {0} - {1}" -f $iss.title, ($iss.description -replace "`r?`n", ' ')) 'ERROR'
                    foreach ($o in @($iss.object)) { if ($o.name) { Write-Log "  object: $($o.name)" 'ERROR' } }
                }
            } else {
                Write-Log "No setup report at $DbReportFile - dumping the installer result document instead." 'WARN'
                Write-InstallerResultXml -SinceUtc ([datetime]::Parse($upgradeStartUtc).ToUniversalTime())
            }
            Write-Log "Full setup logs remain in $SetupTempFolder."
        }
        Restore-VeeamServiceRecovery
        Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs
        # Re-enable the schedules as soon as the installer is done, regardless
        # of its exit code. Memory first - it cannot be lost.
        Restore-PausedJobsFromMemory
        Restore-VeeamJobs

        if ($code -eq 0 -or $code -eq 3010) { break }

        $probe = $null
        try { $probe = Get-InstalledVbrBuild } catch { }
        if ($probe -and $probe.Build -ge $hopMinimum) {
            Write-Log "Installer returned $code, but the core product is at $($probe.Build) (>= required $hopMinimum). PARTIAL SUCCESS - an ancillary component failed:" 'WARN'
            Write-FailedComponentSummary -SinceUtc ([datetime]::Parse($upgradeStartUtc).ToUniversalTime())
            $partialSuccess = $true
            break
        }

        if ($attempt -ge $MaxInstallAttempts) { break }

        $blockers = Get-SetupReportAgentBlockers -ReportPath $DbReportFile
        if ($blockers.OtherErrors.Count -gt 0) {
            Write-Log ("Setup reported blocking error(s) this script cannot remediate: {0}" -f (($blockers.OtherErrors | Select-Object -Unique) -join '; ')) 'ERROR'
            break
        }
        if ($blockers.Names.Count -eq 0) { Write-Log 'No remediable agent blockers found in the setup report - not retrying.' 'WARN'; break }

        Write-Log ("Setup blocked on {0} agent(s): {1}. Remediating and retrying the install once." -f $blockers.Names.Count, ($blockers.Names -join ', ')) 'WARN'
        $fix = Invoke-AgentRemediation -TargetNames $blockers.Names -StaleDays $StaleAgentDays -RestorePointDays $StaleRestorePointDays
        if (($fix.Removed.Count + $fix.Upgraded.Count) -eq 0) {
            Write-Log 'None of the blocking agents could be remediated automatically:' 'ERROR'
            foreach ($b in $fix.Blocked) { Write-Log "  $b" 'ERROR' }
            break
        }
    }

    $AdminPassword = $null

    if (-not $partialSuccess -and $code -ne 0 -and $code -ne 3010) {
        $sinceUtc = $null
        try { if ($upgradeStartUtc) { $sinceUtc = [datetime]::Parse($upgradeStartUtc).ToUniversalTime() } } catch { }
        if ($track -eq 'PATCH' -and $sinceUtc) { Write-PatchFailureEvidence -SinceUtc $sinceUtc }

        # SETUP SAID "REBOOT REQUIRED" - REBOOT ONCE, LET THE NEXT RUN UPGRADE.
        # <SERVER27>, <SERVER28> and <SERVER29>: setup refused with event 013
        # (012 is its prerequisite variant) while the pending-reboot gate read
        # clear. Setup's own check is the one that counts. The jobs were put
        # back on right after the installer exited, and Invoke-ForcedReboot
        # verifies them again before rebooting. Once only: if setup still asks
        # after this script's reboot for it, a person looks.
        $evIds = @()
        if ($sinceUtc) { try { $evIds = @((Get-InstallerEventIds -SinceUtc $sinceUtc).Ids) } catch { } }
        $rbIds = @($evIds | Where-Object { $_ -in @('012','013') })
        if ($rbIds.Count -gt 0) {
            $mk = Get-RebootMarker -Name 'setup-reboot'
            if ($mk -and $mk.rebootedSince) {
                Write-Log ("Setup still says a reboot is required (event {0}) after this script's reboot for it at {1}. Not rebooting again - THIS DEVICE NEEDS A PERSON." -f ($rbIds -join '/'), $mk.rebootedUtc) 'ERROR'
            } else {
                Write-Log ("Setup refused because a reboot is required (event {0}). Rebooting once; the next run performs the upgrade." -f ($rbIds -join '/')) 'WARN'
                Set-RebootMarker -Name 'setup-reboot'
                $script:StateForField = 'REBOOT_FOR_SETUP'
                $exitCode = 2
                Invoke-ForcedReboot -Reason 'setup reported a reboot is required before it will upgrade'
                exit $exitCode
            }
        }

        $probe2 = $null
        try { $probe2 = Get-InstalledVbrBuild } catch { }
        throw "Upgrade failed with exit code $code after $attempt attempt(s); installed build $(if ($probe2) { $probe2.Build } else { 'unreadable' }) did not reach $hopMinimum. See $LogFolder and $SetupTempFolder."
    }

    # =========================================================================
    # STAGE 7 - Verify, write state marker, reboot
    # =========================================================================
    $post = Get-InstalledVbrBuild
    Write-Log "Post-upgrade build: $($post.Build)"
    # On the PATCH track the file version never advances - check the product
    # ARP row instead, or a successful patch reads as a failure.
    if ($track -eq 'PATCH') {
        $postProd = Get-VbrProductArpVersion
        $postProdV = $null
        if ($postProd) { [void][version]::TryParse((($postProd -split '\s')[0]), [ref]$postProdV) }
        Write-Log ("Post-patch product ARP row: {0} (file version stays at {1} by design)" -f `
            $(if ($postProd) { $postProd } else { '<not found>' }), $post.Build)
        if ($postProdV -and $postProdV -ge $PatchTargetBuild) {
            Write-Log "Post-upgrade build: $PatchTargetBuild (patch applied; product ARP row confirms)"
            $script:PatchVerified = $true
        } else {
            try { if ($upgradeStartUtc) { Write-PatchFailureEvidence -SinceUtc ([datetime]::Parse($upgradeStartUtc).ToUniversalTime()) } } catch { }
            throw "Patch ran (installer exit $code) but the product ARP row still reads '$postProd'. Check C:\ProgramData\Veeam\Setup\Temp for the VeeamBackupAndReplication13Patch log from this run."
        }
    }
    elseif ($post.Build -lt $hopMinimum) {
        if ($code -eq 3010) {
            # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED. Setup installed a prerequisite
            # and stopped deliberately BEFORE the product install - <SERVER09>:
            # event id="012" "Reboot is required to finalize prerequisites
            # installation" / Microsoft Visual C++ 2017-2026 Redistributable.
            # Reboot and re-run; the hop completes on the next pass. NOT a failure.
            Write-Log 'Installer returned 3010 with the build unchanged: a prerequisite was installed and needs a reboot before setup will proceed. Rebooting; the next run performs the upgrade.' 'WARN'
            $exitCode = 2
            Invoke-ForcedReboot -Reason 'finalizing installer prerequisites before the upgrade'
            exit $exitCode
        }
        throw "Build did not advance to hop minimum $hopMinimum (found $($post.Build)) although the installer reported $code. Setup exited without upgrading - check $SetupTempFolder for a SuiteEngine log from this run; if none exists, setup never started."
    }
    if ($post.Build -lt $hopTarget) {
        Write-Log "Build $($post.Build) is below the ISO label ($hopTarget) but clears the required floor ($hopMinimum) - acceptable; next run takes the DIRECT track." 'WARN'
    }

    $svc = Get-CimInstance Win32_Service -Filter "Name='VeeamBackupSvc'" -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'Post-upgrade: VeeamBackupSvc is not registered.' }
    if ($svc.StartMode -ne 'Auto') {
        Write-Log "VeeamBackupSvc StartMode is '$($svc.StartMode)' - setting to Automatic." 'WARN'
        Set-Service -Name 'VeeamBackupSvc' -StartupType Automatic
    }

    $svcAll  = @(Get-CimInstance Win32_Service -Filter "Name LIKE 'Veeam%'")
    $svcDown = @($svcAll | Where-Object { $_.State -ne 'Running' })
    Write-Log ("Veeam services pre-reboot: {0} total, {1} running{2}" -f $svcAll.Count, ($svcAll.Count - $svcDown.Count),
        $(if ($svcDown.Count) { "; not running: " + (($svcDown | Select-Object -ExpandProperty Name) -join ', ') } else { '' }))

    $ctlKey = 'HKLM:\SYSTEM\CurrentControlSet\Control'
    $prior  = (Get-ItemProperty -Path $ctlKey -Name 'ServicesPipeTimeout' -ErrorAction SilentlyContinue).ServicesPipeTimeout
    if (-not $prior -or $prior -lt $RestSvcTimeoutMs) {
        Set-ItemProperty -Path $ctlKey -Name 'ServicesPipeTimeout' -Value $RestSvcTimeoutMs -Type DWord
        Write-Log "ServicesPipeTimeout set to $RestSvcTimeoutMs ms (takes effect on the reboot below)."
    }

    [pscustomobject]@{
        fromBuild = [string]$installed; hopTarget = [string]$hopTarget; hopMinimum = [string]$hopMinimum
        upgradeTimeUtc = $upgradeStartUtc; baselineFile = $BaselineFile
        installerCode = $code; partialSuccess = $partialSuccess
        stagingFolder = $script:IsoFolder
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
    Write-Log 'State marker written (next run validates).'

    # Agents do not update themselves and the console's "components" button is
    # this, not Update-VBRServerComponent. Run it on every successful hop -
    # waiting for the validation pass on the NEXT run left 12 sites with
    # failing jobs after the 2026-09-23 wave.
    if ($UpgradeComponents) { try { Invoke-AgentUpdate } catch { Write-Log "Agent update stage failed: $($_.Exception.Message)" 'WARN' } }

    $hopEndBuild = if ($track -eq 'PATCH' -and $script:PatchVerified) { $PatchTargetBuild } else { $post.Build }
    Write-Log "HOP COMPLETE ($installed -> $hopEndBuild)$(if ($partialSuccess) { ' [PARTIAL]' }). Exit 2 = validation pending on next run."
    $script:StateForField = 'HOP_COMPLETE'; $script:StateDetailForField = "$installed -> $hopEndBuild"
    foreach ($mkName in @('setup-reboot','pending-renames','svc-stoppending')) { Clear-RebootMarker -Name $mkName }
    $exitCode = 2
    Invoke-ForcedReboot -Reason "finalizing hop to $hopTarget"
    exit $exitCode
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    $script:StateForField = 'FATAL'; $script:StateDetailForField = [string]$_.Exception.Message
    Write-Log $_.ScriptStackTrace 'ERROR'
    $exitCode = 1
}
finally {
    $AdminPassword = $null
    try { Restore-VeeamServiceRecovery } catch { }
    # If a patch run was cut off mid-window, VeeamManagementAgentSvc is still
    # Manual/stopped and SPC has lost the box. Put it back if it is not Running.
    try {
        $spc = Get-Service -Name 'VeeamManagementAgentSvc' -ErrorAction SilentlyContinue
        if ($spc -and $spc.Status -ne 'Running') { Restore-SpcManagementAgent -OriginalStartMode 'Automatic' }
    } catch { }
    # The services-up step below only restarts services reading Stopped. A
    # VeeamBackupSvc wedged in StopPending was skipped, so nothing could reach
    # Veeam and the jobs stayed off (<SERVER26>). Un-wedge it first.
    try { [void](Reset-WedgedBackupService) } catch { }
    try { Restore-VeeamJobs } catch { Write-Log "Job restore in finally failed: $($_.Exception.Message). CHECK THIS DEVICE - jobs may still be paused." 'ERROR' }

    # SERVICES FIRST. Nothing below can talk to Veeam until these are up.
    # LAST LINE OF DEFENCE. However this run ends - success, throw, gate halt,
    # a stop that timed out - never leave the box with auto-start Veeam
    # services down. A device that exits with its services stopped backs up
    # nothing until something else restarts it. This deliberately runs even on
    # the reboot paths, because a 60 s shutdown delay is long enough for the
    # services to come up and a reboot that never lands would otherwise leave
    # them down indefinitely.
    try {
        # Catch a Disabled core service here too - the check below only sees
        # StartType Automatic, which is exactly how six devices stayed broken.
        try { Repair-DisabledVeeamServices } catch { }
        $down = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
                  Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -eq 'Stopped' })
        if ($down.Count -gt 0) {
            # Naming all 27 services burns ~500 characters of a 10,003
            # character budget and tells a reader nothing they act on.
            $names = @($down | Select-Object -ExpandProperty Name)
            $shown = if ($names.Count -le 6) { $names -join ', ' } else { (($names | Select-Object -First 6) -join ', ') + " and $($names.Count - 6) more" }
            Write-Log ("EXIT GUARD: {0} auto-start Veeam service(s) are stopped - starting them before exit: {1}" -f `
                $down.Count, $shown) 'WARN'

            # THREE ATTEMPTS, NOT ONE. A service can fail to start simply
            # because something it depends on has not finished starting -
            # VeeamCatalogSvc on <SERVER46> reported "start failed" for six
            # consecutive waves while the box was otherwise converged. Start
            # VeeamBackupSvc first, let it settle, then sweep the rest, and
            # repeat before giving up.
            for ($svcTry = 1; $svcTry -le 3; $svcTry++) {
                try {
                    $core = Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue
                    if ($core -and $core.Status -ne 'Running') {
                        Start-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 20
                    }
                } catch { }
                Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs
                $stillDown = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
                               Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' })
                if ($stillDown.Count -eq 0) { break }
                if ($svcTry -lt 3) {
                    Write-Log ("EXIT GUARD: attempt {0} of 3 - still down: {1}. Waiting 30 s and retrying." -f `
                        $svcTry, (($stillDown | ForEach-Object { $_.Name }) -join ', ')) 'WARN'
                    Start-Sleep -Seconds 30
                }
            }

            if ($stillDown.Count -gt 0) {
                Write-Log ("EXIT GUARD: {0} service(s) STILL not running after 3 attempts: {1}. THIS DEVICE IS NOT PROTECTED - check it." -f `
                    $stillDown.Count, (($stillDown | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')) 'ERROR'
                # Say WHY, so the ticket carries something actionable.
                foreach ($sd in $stillDown) {
                    try {
                        $ev = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager'; StartTime=(Get-Date).AddMinutes(-15) } -ErrorAction SilentlyContinue |
                              Where-Object { $_.Message -match [regex]::Escape($sd.Name) } | Select-Object -First 1
                        if ($ev) { Write-Log ("  {0}: {1}" -f $sd.Name, (($ev.Message -replace "`r`n", ' ') -replace '\s{2,}', ' ')) 'ERROR' }
                    } catch { }
                }
            } else {
                Write-Log 'EXIT GUARD: all auto-start Veeam services are running.'
            }
        }
    } catch { Write-Log "EXIT GUARD failed: $($_.Exception.Message). CHECK THIS DEVICE - services may be stopped." 'ERROR' }

    # JOB EXIT GUARD - runs AFTER the service guard, on EVERY path.
    #
    # ORDER MATTERS AND v4.25 HAD IT BACKWARDS. The Veeam cmdlets cannot
    # connect to a stopped VeeamBackupSvc, so a restore attempted while the
    # services are down fails every time. On <SERVER19> and <SERVER48> the log
    # reads, in this order:
    #     COULD NOT RE-ENABLE FROM MEMORY after 3 attempts
    #     FINAL SWEEP: ... Re-enabling everything that is still disabled
    #     EXIT GUARD: 27 auto-start Veeam service(s) are stopped - starting them
    # Both restore passes ran against a dead API and both failed. By the time
    # the services came up, there was nothing left to do the restoring. Two
    # sites were left dark by an ordering mistake, not a logic one.
    # A site whose jobs are disabled backs up nothing, and v4.7 left three of
    # them that way for over 24 hours. Restore-VeeamJobs handles the normal
    # case from the state file; this catches everything else - a FATAL before
    # the restore, a state file that never got written, a restore that partly
    # failed. Repair-AllJobsDisabled only revives jobs with a session in the
    # last 30 days, so a deliberately-quiesced site is left alone.
    # The service guard above may have only just started VeeamBackupSvc. SCM
    # reporting Running is not the same as the API answering, and a restore
    # against a half-started service fails exactly like one against a stopped
    # service. Wait for a real response before trying.
    try {
        # The old probe here never called Veeam, so it could report the API up
        # while job queries were refused. Wait-VeeamJobApi runs a real
        # Get-VBRJob.
        $apiSecs = Wait-VeeamJobApi -TimeoutSeconds 120
        if ($apiSecs -ge 0) { Write-Log ("Veeam API responding after {0}s - restoring job state." -f $apiSecs) }
        else { Write-Log 'Veeam did not answer a job query within 120s. Attempting the job restore anyway.' 'WARN' }
    } catch { }

    try {
        Restore-PausedJobsFromMemory
        Restore-VeeamJobs
        Repair-AllJobsDisabled
    } catch { Write-Log "JOB EXIT GUARD failed: $($_.Exception.Message). CHECK THIS DEVICE - jobs may be disabled." 'ERROR' }

    # FINAL SWEEP: if ANY job is still disabled at exit and this run paused
    # anything at all, re-enable it. No conditions, no 30-day rule, no state
    # file. A site that was backing up when this script started must be backing
    # up when it finishes.
    try {
        if (@($script:PausedJobNames).Count -gt 0) {
            Write-Log 'FINAL SWEEP: this run paused jobs and the memory restore did not confirm. Re-enabling everything that is still disabled.' 'ERROR'
            $chk = $null
            try { $chk = Invoke-VeeamQuery -Script @'
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) { try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { } }
  $out = @()
  foreach ($j in @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)) {
    $en = $false
    foreach ($p in @('IsScheduleEnabled','JobEnabled','Enabled','IsEnabled')) {
      if ($j.PSObject.Properties.Name -contains $p) { $en = [bool]$j.$p; break }
    }
    if (-not $en) { $out += [string]$j.Name }
  }
  @{ ok=$true; disabled=@($out) } | ConvertTo-Json -Depth 3 -Compress
} catch { @{ ok=$false; error=[string]$_.Exception.Message } | ConvertTo-Json -Compress }
'@ } catch { }
            if ($chk -and $chk.ok -and @($chk.disabled).Count -gt 0) {
                $fix = Invoke-JobRestoreQuery -Names @($chk.disabled)
                if ($fix -and $fix.ok) {
                    Write-Log ("FINAL SWEEP: re-enabled {0} job(s): {1}" -f @($fix.restored).Count, (@($fix.restored) -join ', ')) 'WARN'
                    if (@($fix.failed).Count -gt 0) { Write-Log ("FINAL SWEEP COULD NOT RE-ENABLE: {0}. THIS SITE IS NOT BACKING UP - fix it now." -f (@($fix.failed) -join '; ')) 'ERROR' }
                }
            } elseif ($chk -and $chk.ok) {
                Write-Log 'FINAL SWEEP: no jobs are disabled. Site is backing up.'
            }
        }
    } catch { Write-Log "FINAL SWEEP failed: $($_.Exception.Message). CHECK THIS DEVICE NOW - jobs may be disabled." 'ERROR' }

    # Record the outcome before any cleanup, so the field is written even if
    # something below throws.
    # The veeamUpgradeState custom field was never created - you chose the
    # read-only collector instead - so the write that stood here only added
    # "Unable to find the specified field" errors to every log. Removed.

    try { Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    if ($mountedIso) { try { Dismount-DiskImage -ImagePath $mountedIso | Out-Null } catch { } }
    Get-ChildItem -LiteralPath $LogFolder -Filter 'veeamq_*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch { }
    if ($haveMutex) { try { $mutex.ReleaseMutex() } catch { } }
}

exit $exitCode