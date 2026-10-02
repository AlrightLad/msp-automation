## What this changes

<!-- One paragraph. Name the script, what it does differently, and which `$env:` inputs or exit codes changed. -->

## Gate

- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning, Error` returns nothing (inline suppressions carry a justification)
- [ ] Pester passes, with a happy path and a failure path for every decision helper this change touches
- [ ] Comment-based help is present and documents every `$env:` input, what the script changes, and what each exit code means
- [ ] RMM-safety contract honoured: no `Read-Host`, no `[switch]`, single-instance mutex with `AbandonedMutexException` handling, `Start-Transcript` with rotation, exit codes 0 / 1 / 2, 32-bit host handling, accurate `#Requires` floor
- [ ] Pre-push scan from the pattern file returns nothing (no hostnames, client or site names, tickets, UNC paths, internal URLs, credential field values)
- [ ] Every commit is signed and shows "Good signature"

## How it was verified

<!-- Analyzer and Pester output, and the device class the script was run on with the report-only input. -->
