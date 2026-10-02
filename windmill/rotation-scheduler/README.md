# Rotation scheduler — reference implementation

The backend module of an on-call rotation scheduler, extracted from a Windmill app (the
Schedule tab of an operations dashboard), together with its test file. It is published as a
**reference implementation**: the code is real and was in production, but this directory is
**not independently runnable**.

- `rotation.ts` imports `windmill-client` and `postgres`, reads Windmill resources and
  secret variables, and reads and writes Postgres tables that a separate migration created.
- `rotation.test.ts` runs under Bun. It transpiles `rotation.ts` with the two runtime imports
  stubbed out and exercises the pure functions. Its "presence writer (phase 4)" block also
  loads a sibling `oncall_presence_writer.ts`, which is **not** part of this extraction; the
  writer's presence arithmetic is published on its own as
  [ringcentral-queue-presence](https://github.com/AlrightLad/ringcentral-queue-presence).

Read it for the design. Run the sibling repo for the part that talks to RingCentral.

## What the module does

**The roster lives in config, not code.** One JSON document (`ops_rotation`) holds the on-call
pool and its anchor Monday, the standing-escalation row, and the Saturday pool and approver.
Each section is validated and falls back independently, and the response says which source
each section came from, so a typo in one list cannot blank the other.

**A deterministic cycle.** `pickRoster()` picks the holder from how many whole weeks a date is
from the anchor. No state, no "next person" pointer to drift.

**Swaps are an override layer, never a roster edit.** A swap is a dated exception stored
separately; the base cycle is never reordered. The effective holder of a day is the base pick
with accepted swaps applied in decision order (`holderOn()`). On-call swaps are mutual consent
between the two parties; Saturday swaps have a single approver. Swaps cover a half-open range
of days that never crosses a week boundary, may offer an exchange, can be chained by the new
holder, expire at the end of their first covered day, and an accepted swap whose giver no
longer holds the day is skipped and reported rather than stacked.

**Manager reassignments.** A rotation admin can move a range to someone with no counterparty
consent. A reassignment stands over any swap, a later one wins where they overlap, and pending
requests it covers close as superseded, with each party told separately.

**A live drift check against RingCentral.** `assessDrift()` compares the effective on-call to
the call queue's presence: exactly one rotation member should be enabled, and it must be the
effective holder. A named exception (the standing-escalation row plus `drift_exempt`) is
removed from the set the invariant is evaluated over. The check reports the silent coverage
failure, a member enabled for the queue whose extension refuses queue calls, as `bad`, and
reads "cutover pending" softly before the Monday cutover time.

**Saturday checklist as a server-side record.** Only the effective holder may tick, decided
from the job's end-user email; the window opens at shift start and closes Monday morning so a
forgotten tick can still be recorded over the weekend while a late tick still reads as late.

**Coverage snapshots and history.** Who actually held a Saturday is recorded once the shift
ends (three idempotent write moments), and history reads the record rather than recomputing
from today's roster, so a roster change can never rewrite the past. Each history row carries
an evidence flag: ticked with no PSA activity, worked with no ticks, no evidence at all.

**Identity and authorisation server-side.** The actor is the Windmill end-user email of the
run, never a client-supplied string. Admin capabilities come from a Windmill group that the
people it governs cannot edit through the dashboard; an empty or unreadable group switches
them off.

**Notifications are latency, not coverage.** Teams Adaptive Cards are posted best effort to a
webhook and the result is recorded on the swap; a failure never blocks the request.

**Storage: tables first, blobs second.** Rows live in Postgres tables when they exist and in
JSON blobs otherwise, with a verified, idempotent migration between them.

**The presence writer is orchestrated, not embedded.** The dashboard reports the writer's
on/off switch, which lives in a Windmill variable and arms only on the exact string `"true"`,
and kicks the writer after an accepted swap or a reassignment that touches today.

## Sanitization

Only literals and comments were changed. Every substitution is mechanical and the test file
was transformed with the same rules, so the assertions still match the module.

| In the source | Here |
|---|---|
| Engineer names, first names, identifiers | `<ENGINEER_1>` … `<ENGINEER_13>`, `eng1` … `eng8` |
| Phone extensions | `1001` … `1013` (test fixtures `111`–`115`, `555`, `700`, `701`, `888`, `999` kept) |
| RingCentral member ids | `<RC_ID_n>` |
| Default RingCentral account and queue ids | removed; the resource must supply them (`\|\| ""`) |
| The emergency line's number and queue dialing extension | removed |
| PSA vendor name and its table names | `PSA`, `psa_agent`, `psa_action`, `psa_ticket_id` |
| KB and SOP page numbers | `0`, with prose references made generic |
| Knowledge-base and Windmill hostnames | `<KB_HOST>`, `<WINDMILL_HOST>` |
| Workspace names | `<WORKSPACE>`, `<DEV_WORKSPACE>` |
| Internal team name | `Tier 3` |
| Password-manager vault and item references | removed |
| PSA agent ids in test fixtures | renumbered |
| Test file paths | point at this directory |
| Millisecond constants `86400000` and `3600000` (five occurrences) | `86_400_000` and `3_600_000`, numeric separators, same values; this repository's pre-push scan flags long digit runs |

Everything else, including the comment-based rationale, is verbatim.

## See also

- [ringcentral-queue-presence](https://github.com/AlrightLad/ringcentral-queue-presence):
  the queue-presence client the writer half of this design runs on, with the four RingCentral
  behaviours documented.
