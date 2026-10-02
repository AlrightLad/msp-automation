# Contributing

Pull requests are welcome. The bar is the same for every file, including mine.

## Before you open a PR

1. **PSScriptAnalyzer is clean at Warning and Error.**

   ```powershell
   Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning,Error
   ```

   Must return nothing. Do not suppress a rule to make it pass. If a rule is
   genuinely wrong for the case, say why in the PR and we decide together.

2. **Pester covers a happy path and a failure path** for the script you touched.
   Tests live in `tests/<script-name>.Tests.ps1` and run with Pester 5 or later:

   ```powershell
   Invoke-Pester -Path tests/
   ```

   Tests must not need the vendor product installed, network access, or
   administrator rights. Mock the boundary and test the decision.

3. **Comment-based help on every script.** `.SYNOPSIS`, `.DESCRIPTION`, the
   environment variables the script reads, what it changes, and what each exit
   code means.

4. **The script honors the RMM-safety contract** in [README.md](README.md). If
   you are bringing a new script in, remediate it to the contract first and keep
   that remediation in its own commits so the diff against the source is honest.

5. **Every commit is GPG-signed.** `git commit -S`, then confirm with
   `git log --show-signature -1` before you push. Unsigned commits are not merged.

## Commit messages

```
add(<category>): <script-name> — sanitized from production
fix(<category>): <script-name> — <what changed>
```

Categories match the top-level directories.

## Sanitization

Nothing that identifies a customer, host, network, ticket, person, or
credential is accepted, in code or in comments. Use the placeholders listed in
README.md. Delete example output and sample log lines rather than editing them.
Run the pre-push scan from the repo root before you open the PR:

```bash
grep -rniE 'dtctoday|192\.168|10\.[0-9]+\.[0-9]+\.[0-9]+|\\\\[A-Z0-9-]{4,}\\|[0-9]{7}|IKEY|SKEY|backblazeb2|public-dtc' .
```

It must return nothing.
