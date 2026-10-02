# Security policy

Everything in this repository runs as SYSTEM, from an RMM, across fleets of servers and
workstations it has never seen. Several scripts stop services, install software, read a
secure custom field for a local administrator credential, or reboot. A defect here is not a
bug in a web page; it is a fleet-wide change executed with elevated privilege and no human at
the keyboard. Treat a vulnerability report accordingly.

## Supported versions

Only the current `main` branch is supported. There are no release branches; a fix lands on
`main`, with a signed commit, and the commit is the fix. Pin the commit SHA of the script you
deploy and record it in your RMM, so you can tell what is running.

| Version | Supported |
|---|---|
| `main` (latest commit) | yes |
| any earlier commit | no, update to `main` |

## Reporting a vulnerability

Please report privately. Do not open a public issue for anything that could be used against
a fleet running these scripts.

- Email: **zboogher@gmail.com**, subject line starting with `[msp-automation security]`.
- Or use GitHub's private vulnerability reporting on this repository if it is enabled
  (Security tab → Report a vulnerability).

Include the script name and the commit SHA you tested, the PowerShell version and host
architecture (32- or 64-bit RMM host), what you found, how to reproduce it, and whether you
believe it is already being exploited. Do not include your tenant's hostnames, credential
field names or transcripts with identifiers; redact first.

**Response time.** Acknowledgement within 3 business days; an assessment with a planned fix or
an explanation within 14 days. Anything that lets a script run interactively, escape its
single-instance mutex, write a credential to its transcript, or act on a device the inputs
did not target is treated as critical and fixed first.

## What counts

In scope: credential handling (anything that writes a secure-field value to the transcript or
a file, or retains it after use); the RMM-safety contract (a path to `Read-Host`, a `[switch]`
that cannot bind from an RMM preset, a missing or bypassable mutex, exit codes outside 0/1/2
that an RMM would misread); input handling (an `$env:` value that reaches a shell, a path, or
a scheduled-task definition unvalidated); download and install paths (an ISO or installer
accepted without the configured SHA-256 match); and anything that lets a report-only run make
a change.

Out of scope: vulnerabilities in the vendor products the scripts manage (Veeam, Dell, Intel,
Windows itself); findings that require an already-compromised RMM tenant or SYSTEM on the host.

## These are sanitized references

Every script here was extracted from a production script library and sanitized: client,
site and host names, ticket numbers, internal paths, custom-field ids and credentials were
replaced with placeholders or made `$env:` inputs. Logic was preserved; the environment it
ran in was not. The Pester tests exercise the decision helpers and assert the contract
structurally; they do not install Veeam or reboot anything.

**Operators are responsible for reviewing a script before deploying it to a fleet.** Read the
comment-based help and every `$env:` input it documents, decide which placeholder defaults
(`<LOCAL_ADMIN>`, `ORG`, the custom-field names) must be set for your tenant, run it with the
report-only input first on one device, and keep the transcript. The maintainer has no
visibility into your fleet and has not tested these scripts against it.
