# msp-automation

![CI](https://github.com/AlrightLad/msp-automation/actions/workflows/ci.yml/badge.svg)

PowerShell automation for managed Windows infrastructure, written to run
unattended under an RMM against a fleet of several thousand endpoints.

Every script in this repository was lifted from production, sanitized, and
brought to the contract below before it was committed. This is a curated
subset. More is added as each script is brought to contract, not before.

## The RMM-safety contract

An RMM runs a script with no console, no operator, and no second chance. A
script that prompts hangs the job. A script that returns the wrong exit code
lies to the alerting that depends on it. Every script here honors all seven
rules, and a reader can open any file and check.

| Rule | What it means in the code |
|---|---|
| **No interactive input** | No `Read-Host`, no `Get-Credential`, no `Pause`, no "press any key". Not even as a fallback when run by hand. |
| **Input via `$env:`, never `[switch]`** | RMM platforms pass script variables as environment variables. `[switch]` parameters do not bind from environment variables and fail silently, so every input is read from `$env:` with a sane default. Boolean inputs accept `true`/`1`. |
| **Single-instance mutex** | A named `System.Threading.Mutex` guards each run. A second instance exits at once instead of racing the first: `2` for a remediation script, `0` for a monitor that must not raise a false alarm. An abandoned mutex from a crashed run is acquired, not treated as fatal. |
| **Transcript with rotation** | `Start-Transcript` writes to the RMM's log root, and older transcripts for the same script are pruned so a scheduled job cannot fill a disk over months. |
| **Exit codes 0 / 1 / 2** | `0` success, `1` failure, `2` warning. Nothing else. The RMM maps these to conditions and tickets, and a vendor installer's `3010` has no meaning to it. |
| **32-bit host by default** | RMM agents typically launch 32-bit PowerShell. Scripts work there. A script that genuinely needs the 64-bit host (Hyper-V, Veeam, some vendor modules) relaunches itself through `sysnative` and returns the child's exit code. |
| **Minimum PowerShell 5.1** | Declared with `#Requires -Version 5.1`, and no PowerShell 7-only syntax. A script that deliberately targets older hosts declares its real floor and says why in its help: the Dell lifecycle audit runs on WMF 3 servers and declares 3.0. |

Scripts that are **read-only by design** (audits, collectors) say so in their
help and make no change to the host.

## Layout

```
backup-veeam/     Veeam Backup & Replication and Veeam Agent
msft-windows/     Windows Server and workstation OS
oem-dell/         Dell PowerEdge and OptiPlex / Precision
oem-intel/        Intel platform components (RST / VROC RAID)
windmill/         TypeScript reference implementations extracted from Windmill apps;
                  documented design, not runnable here (see each README)
tests/            Pester tests, one file per script
.github/          CI: PSScriptAnalyzer and Pester on every push and PR
```

One script per file. Each script's comment-based help documents the inputs it
reads from the environment, what it changes, and what each exit code means.

## Sanitization

These scripts ran against real customers. Before publication every one was
sanitized by rule, not by eye:

- Customer, site, and organization names become `<CLIENT>`.
- Hostnames become `<SERVER01>` or `<WORKSTATION01>`; IPs and subnets become
  `10.x.x.x`; UNC paths become `\\<SERVER01>\<SHARE>`.
- Artifact download hosts become `https://<BUCKET_HOST>/<PATH>`.
- RMM organization, location, document, custom-field, and template IDs become
  `<GUID>` or `<FIELD_ID>`.
- Ticket numbers, internal knowledge-base references, and people's names are
  removed.
- Keys, tokens, license strings, and credentials are removed outright.
- Sample log lines, example output, and file listings in comments are deleted,
  because in a healthcare fleet an "example" string may be a patient
  identifier.

Logic is preserved verbatim. Variable names, casing, inline comments, and the
template header each script was born with are left as they were. Sanitization
changes identifiers; it does not refactor.

## Running a script under an RMM

1. Upload the script as-is. Do not wrap it; each script handles its own
   64-bit relaunch, logging, and locking.
2. Define the inputs the script's help lists as **script variables** (NinjaOne)
   or the equivalent in your platform. They arrive as `$env:<Name>`.
   Boolean inputs take `true` or `1`.
3. Run as SYSTEM. The scripts expect the 32-bit host and relaunch when they
   need 64-bit.
4. Map exit codes: `0` healthy, `1` failed (ticket), `2` warning (review).
5. Transcripts land under the RMM agent's scripting directory when
   `$env:RMMScriptPath` is set, otherwise under `%ProgramData%`.

To run one by hand for testing, set the same variables in the session first:

```powershell
$env:Description = 'change-1234'
$env:ReportOnly  = 'true'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\oem-dell\get-server-lifecycle-audit.ps1
Write-Host "exit $LASTEXITCODE"
```

## Quality gate

Nothing merges unless PSScriptAnalyzer is clean at Warning and Error, Pester
passes a happy path and a failure path for the script, comment-based help is
present, and the commit is GPG-signed. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
