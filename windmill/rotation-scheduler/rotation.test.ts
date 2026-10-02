// Extracts the REAL pure functions out of rotation.ts (beside this file; in the Windmill app it lives at
// f/rmm/ops_dashboard__raw_app/backend/rotation.ts) and
// asserts the rota invariants against them: config resolution and fallback, the five-week on-call
// cycle from its anchor, the RingCentral drift check with the CTO exemption, and the Saturday list.
// Same approach as offboard_gate.test.ts — no copy of the logic lives here. The file's two runtime
// imports (windmill-client, postgres) are stripped; the functions that use them are never called.
import { readFileSync } from "fs";
import { resolve } from "path";

const src = readFileSync(resolve(import.meta.dir, "rotation.ts"), "utf8");
const stripped = src
  .replace(/^import \* as wmill from "windmill-client";\s*$/m, "const wmill = undefined;")
  .replace(/^import postgres from "postgres";\s*$/m, "const postgres = undefined;")
  .replace(/^export (const|function|type|async function) /gm, "$1 ");
const js = new Bun.Transpiler({ loader: "ts" }).transformSync(`${stripped}
globalThis.__rot = { flagIsOn, resolveConfig, DEFAULTS, MOCK_SWING, ONCALL, SWING, CONFIG_KEY, SWAPS_KEY, etNow, mondayOf, saturdayOnOrAfter, pickRoster,
  buildOncall, buildSwing, normalizeRc, assessDrift, assemble, sameAs, jobActor, UNATTRIBUTED,
  etMidnightMs, periodStartMs, swapStatus, coverFor, pendingFor, validateRequest, authorizeDecision, applySwapAction, samePerson, viewerRoles, partyOf, membershipOf,
  CHK_KEY, chkWindow, chkRecord, chkSummary, applyTick, buildHistory, matchPeople, normalizeRcExtensions, SWING,
  swapEvent, adaptiveCard, notifyPayload, DASHBOARD_URL, passedSaturdays, snapshotFor, freezeCoverage, COVERAGE_KEY, historyOmitted, isAdmin, adminFields, adminGate, ADMIN_GROUP,
  holderOn, weekRuns, rangeLabel, normSwap, acceptedSorted, pendingOverlapping, wholeWeek, isWholePeriod, swapStartMs, swapExpiresMs, periodEndMs, swapView, swapEffectiveAt,
  applyOverride, cancelOverride, activeOverrides, overrideEvent, supersededEvent, overrideView, podUrl, activityFinal, etMidnightMs };`);
new Function(js)();
const R: any = (globalThis as any).__rot;
if (typeof R?.assessDrift !== "function") throw new Error("failed to extract rotation functions");

let pass = 0, fail = 0;
function check(name: string, cond: boolean, detail?: any) {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.log(`  FAIL ${name}${detail !== undefined ? "  → " + JSON.stringify(detail) : ""}`); }
}
const et = (iso: string) => R.etNow(Date.parse(iso));
const eq = (a: any, b: any) => JSON.stringify(a) === JSON.stringify(b);
const D = R.DEFAULTS;
const [eng1, eng2, eng3, eng4, eng5] = D.oncall.pool;
const eng6 = D.oncall.cto;
const rec = (p: any, cq: boolean, aq: boolean | null = true) => ({ id: p.rc_id ?? null, name: p.name, ext: p.ext, acceptCurrentQueueCalls: cq, acceptQueueCalls: aq });
// The live queue as seen 2026-09-10: five rotation members plus the CTO, <ENGINEER_5> enabled.
const liveQueue = (over: Record<string, [boolean, boolean]> = {}) =>
  [eng6, eng1, eng2, eng3, eng4, eng5].map(p => { const o = over[p.ext] ?? [p.ext === eng5.ext, true]; return rec(p, o[0], o[1]); });

console.log("config resolution");
{
  const r0 = R.resolveConfig(null);
  check("no row → defaults, sources default/mock, no problems", r0.oncall_source === "default" && r0.swing_source === "mock" && r0.problems.length === 0);
  check("default pool is the five, in the given order", eq(r0.cfg.oncall.pool.map((p: any) => p.ext), ["1001", "1002", "1003", "1004", "1005"]));
  check("<ENGINEER_6> is the CTO row, not in the pool", r0.cfg.oncall.cto.ext === "1006" && !r0.cfg.oncall.pool.some((p: any) => p.ext === "1006"));
  check("CTO guidance is the plain-sight sentence", r0.cfg.oncall.cto.guidance === "CTO escalation — Tier 3 only, or if the on-call Tier 3 engineer does not respond.");
  check("Saturday approver defaults to <ENGINEER_4> x1004", r0.cfg.swing.approver?.name === "<ENGINEER_4>" && r0.cfg.swing.approver?.ext === "1004");

  const good = { oncall: { pool: [{ name: "A B", ext: "1" }, { name: "C D", ext: "2" }], anchor: "2026-09-07" } };
  const r1 = R.resolveConfig(good);
  check("valid oncall section → source config, swing untouched (mock)", r1.oncall_source === "config" && r1.swing_source === "mock" && r1.cfg.oncall.pool.length === 2 && r1.problems.length === 0);
  check("cto keeps the default when the section omits it", r1.cfg.oncall.cto.ext === "1006");
  const nameOnly = R.resolveConfig({ oncall: { pool: [{ name: "No Ext" }], anchor: "2026-09-07" } });
  check("a row without an extension is rejected and the section falls back", nameOnly.oncall_source === "default" && /both required/.test(nameOnly.problems[0] ?? ""));
  const badAnchor = R.resolveConfig({ oncall: { pool: [{ name: "A", ext: "1" }], anchor: "2026-09-09" } });
  check("a non-Monday oncall anchor is rejected", badAnchor.oncall_source === "default" && /not a Monday/.test(badAnchor.problems[0] ?? ""));
  const badSat = R.resolveConfig({ swing: { pool: [{ name: "A", ext: "1" }], anchor: "2026-09-13" } });
  check("a non-Saturday swing anchor is rejected", badSat.swing_source === "mock" && /not a Saturday/.test(badSat.problems[0] ?? ""));
  const appr = R.resolveConfig({ swing: { approver: null } });
  check("swing.approver: null clears the approver without touching the pool", appr.cfg.swing.approver === null && appr.swing_source === "mock" && appr.problems.length === 0);
  const asText = R.resolveConfig(JSON.stringify(good));
  check("a JSON string value is accepted (jsonb read back as text)", asText.oncall_source === "config");
  check("garbage is reported, not thrown", R.resolveConfig("not json").problems.length === 0 && R.resolveConfig(42).problems.length === 1);
}

console.log("on-call cycle");
{
  const o = R.buildOncall(et("2026-09-09T20:00:00Z"), D.oncall, 4);      // Wed Sep 9, 16:00 ET
  check("week of 2026-09-07 resolves to <ENGINEER_5> (RingCentral had him enabled)", o.current.name === "<ENGINEER_5>" && o.current.week_start === "2026-09-07" && o.current.week_end === "2026-09-13");
  check("previous week was <ENGINEER_4>", o.previous.name === "<ENGINEER_4>");
  check("next four: <ENGINEER_1>, <ENGINEER_2>, <ENGINEER_3>, <ENGINEER_4> — a five-week cycle", eq(o.upcoming.map((w: any) => w.name), ["<ENGINEER_1>", "<ENGINEER_2>", "<ENGINEER_3>", "<ENGINEER_4>"]) && o.cycle_weeks === 5);
  check("cutover window only Monday before 9:00 ET", !o.cutover_pending && R.buildOncall(et("2026-09-14T12:30:00Z"), D.oncall).cutover_pending && !R.buildOncall(et("2026-09-14T13:00:00Z"), D.oncall).cutover_pending);
  check("approval model is mutual consent, no approver field", o.approval.model === "mutual" && !("approver" in o));
  check("etNow renders the ET calendar date, not UTC", et("2026-09-10T02:30:00Z").ymd === "2026-09-09");
}

console.log("drift with the CTO exemption");
{
  const ex = [eng6];
  const ok = R.assessDrift(eng5, eng4, liveQueue(), false, ex);
  check("live 2026-09-10 queue against the real roster → ok", ok.state === "ok" && ok.exempt.length === 1 && ok.exempt[0].ext === "1006");
  const ctoOn = R.assessDrift(eng5, eng4, liveQueue({ "1006": [true, true] }), false, ex);
  check("CTO enabled as well → still ok (never the extra member)", ctoOn.state === "ok" && !ctoOn.findings.some((f: any) => /2 rotation members/.test(f.text)));
  const ctoOff = R.assessDrift(eng5, eng4, liveQueue({ "1006": [false, false] }), false, ex);
  check("CTO disabled and refusing queue calls → still ok (never flagged)", ctoOff.state === "ok");
  const onlyCto = R.assessDrift(eng5, eng4, liveQueue({ "1005": [false, true], "1006": [true, true] }), false, ex);
  check("only the CTO enabled → bad: no on-call is taking calls", onlyCto.state === "bad" && onlyCto.headline === "No on-call is taking queue calls");
  const noExempt = R.assessDrift(eng5, eng4, liveQueue({ "1006": [true, true] }), false, []);
  check("without the exemption the same queue would warn (proves the exemption is doing the work)", noExempt.state === "warn");
  const dnd = R.assessDrift(eng5, eng4, liveQueue({ "1005": [true, false] }), false, ex);
  check("on-call enabled but extension refuses queue calls → bad, silent coverage failure", dnd.state === "bad" && dnd.headline === "Silent coverage failure");
  const stale = liveQueue({ "1005": [false, true], "1004": [true, true] });
  check("last week's on-call still enabled → cutover pending before 9 AM Monday, drift after", R.assessDrift(eng5, eng4, stale, true, ex).headline === "Cutover pending" && R.assessDrift(eng5, eng4, stale, false, ex).state === "warn");
  const two = R.assessDrift(eng5, eng4, liveQueue({ "1001": [true, true] }), false, ex);
  check("two rotation members enabled → warn naming the extra", two.state === "warn" && two.findings.some((f: any) => /<ENGINEER_1> \(x1001\)/.test(f.text)));
  const gone = R.assessDrift({ name: "New Hire", ext: "999" }, eng4, liveQueue({ "1005": [false, true] }), false, ex);
  check("on-call not in the queue and nobody enabled → bad + not-a-member", gone.state === "bad" && gone.findings.some((f: any) => /not a member/.test(f.text)));
  check("sameAs matches on rc_id first, then extension, then name", R.sameAs(rec(eng5, true), { name: "someone else", ext: "0", rc_id: "<RC_ID_5>" }) && R.sameAs(rec(eng5, true), { name: "x", ext: "1005" }) && R.sameAs(rec(eng5, true), { name: "<engineer_5>", ext: "" }));
  const m = R.normalizeRc({ records: [{ member: { id: 1, extensionNumber: "1005", name: "<ENGINEER_5>" } }] });
  check("normalizeRc keeps unknown flags as null, never false", m[0].acceptQueueCalls === null && m[0].acceptCurrentQueueCalls === null && m[0].id === "1");
}

console.log("Saturday swing");
{
  const s = R.buildSwing(et("2026-09-09T20:00:00Z"), D.swing, 4);
  check("next four Saturdays, first marked next", eq(s.saturdays.map((x: any) => x.date), ["2026-09-12", "2026-09-19", "2026-09-26", "2026-10-03"]) && s.saturdays[0].status === "next");
  check("in progress during the shift, rolls over after 1 PM", R.buildSwing(et("2026-09-12T14:00:00Z"), D.swing).saturdays[0].status === "in_progress" && R.buildSwing(et("2026-09-12T18:00:00Z"), D.swing).saturdays[0].date === "2026-09-19");
  check("single-approver model naming <ENGINEER_4>", s.approval.model === "single" && /<ENGINEER_4> \(x1004\)/.test(s.approval.text));
  check("checklist is the five tickable items from the KB; the handoff is a note, not an item", eq(R.SWING.checklist.map((c: any) => c.n), [1, 2, 3, 4, 5]) && R.SWING.checklist_note?.label === "Escalation and handoff" && /<ENGINEER_6> \(x1006\)/.test(R.SWING.checklist_note.body) && /TECHS chat in Teams/.test(R.SWING.checklist_note.body) && R.SWING.checklist_note.flag === "anything verbal goes in PSA" && !R.SWING.checklist.some((c: any) => /Handoff|Escalation/.test(c.label)) && R.SWING.sop_page === 0 && R.ONCALL.sop_page === 0);
  check("corrected wording: NinjaOne alerts in PSA (T1 Ingress) and the NOC board; Veeam on the NOC board only; item 5 reviews the Saturday's schedule", /PSA → Alerts on T1 Ingress · PSA NOC board/.test(R.SWING.checklist[2].where) && R.SWING.checklist[3].where === "PSA NOC board" && !/NinjaOne alerts or VSPC/.test(R.SWING.checklist[3].where) && /scheduled for this Saturday/i.test(R.SWING.checklist[4].label));
  check("a stored tick for the old item 6 is neither shown nor scored", R.chkSummary({ name: "x", email: null, ext: "1", ticks: { "1": "2026-09-12T12:00:00Z", "6": "2026-09-12T12:01:00Z" }, updated_at: "" }, R.SWING.checklist.length, "2026-09-12").done === 1);
}

console.log("audit attribution");
{
  const viewer = R.jobActor({ WM_END_USER_EMAIL: "tech@example.com", WM_EMAIL: "admin@windmill.dev", WM_PERMISSIONED_AS: "u/admin", WM_JOB_ID: "j1" });
  check("actor is the app viewer's email from WM_END_USER_EMAIL, never the publisher's WM_EMAIL", viewer.actor === "tech@example.com" && viewer.job_email === "admin@windmill.dev" && viewer.permissioned_as === "u/admin");
  const none = R.jobActor({ WM_END_USER_EMAIL: "", WM_EMAIL: "admin@windmill.dev" });
  check("empty end-user email → recorded as unattributed, not as the publisher", none.actor === R.UNATTRIBUTED && none.end_user_email === null);
  check("whitespace-only end-user email is treated as empty", R.jobActor({ WM_END_USER_EMAIL: "   " }).actor === R.UNATTRIBUTED);
  check("no actor parameter exists on main()", !/export async function main\([^)]*actor/.test(src));
}

console.log("swaps: an override layer, never a roster edit");
{
  // The document saved to <DEV_WORKSPACE> 2026-09-10: four-week on-call cycle from 2026-08-17, six Saturdays from 2026-09-05.
  const cfg = R.resolveConfig({
    oncall: { pool: [{ name: "<ENGINEER_1>", ext: "1001" }, { name: "<ENGINEER_2>", ext: "1002" }, { name: "<ENGINEER_3>", ext: "1003" }, { name: "<ENGINEER_5>", ext: "1005" }], anchor: "2026-08-17" },
    swing: { pool: [{ name: "<ENGINEER_7>", ext: "1007" }, { name: "<ENGINEER_8>", ext: "1008" }, { name: "<ENGINEER_9>", ext: "1009" }], anchor: "2026-09-05", approver: { name: "<ENGINEER_4>", ext: "1004" } },
  }).cfg;
  const [Z, T, M, S] = cfg.oncall.pool;
  const now = et("2026-09-10T20:00:00Z");
  const idOf = (p: any, email: string) => ({ agent_id: 1, name: p.name, email, ext: p.ext });
  const eng5 = idOf(S, "eng5@x"), eng1 = idOf(Z, "eng1@x"), eng2 = idOf(T, "eng2@x"), eng3 = idOf(M, "eng3@x");
  const eng4 = { agent_id: 9, name: "<ENGINEER_4>", email: "eng4@x", ext: "1004" };
  const poolSnapshot = JSON.stringify(cfg.oncall.pool);

  check("ET midnight is DST-correct (EDT in Sep = 04:00Z, EST in Dec = 05:00Z)", R.etMidnightMs("2026-09-14") === Date.parse("2026-09-14T04:00:00Z") && R.etMidnightMs("2026-12-07") === Date.parse("2026-12-07T05:00:00Z"));
  check("a Saturday period starts at 08:00 ET", R.periodStartMs("swing", "2026-09-12") === Date.parse("2026-09-12T12:00:00Z"));

  // request → accept, with an exchange
  let st = R.applySwapAction("swap_request", { kind: "oncall", period: "2026-10-05", counterparty_ext: "1001", exchange: "2026-09-14", note: "trip" }, eng5, cfg, [], now);
  const req = st.swap;
  check("request stored pending with both parties carrying extensions", req.status === "pending" && req.from.ext === "1005" && req.to.ext === "1001" && req.exchange?.week_start === "2026-09-14" && req.exchange?.covers.to === "2026-09-21");
  check("pending changes nothing", R.coverFor("oncall", "2026-10-05", S, st.swaps, now.ms).holder.ext === "1005");
  let threw = "";
  try { R.applySwapAction("swap_accept", { id: req.id }, eng2, cfg, st.swaps, now); } catch (e: any) { threw = e.message; }
  check("a third party cannot accept (server-side)", /only the counterparty, <ENGINEER_1>/.test(threw));
  threw = ""; try { R.applySwapAction("swap_accept", { id: req.id }, eng5, cfg, st.swaps, now); } catch (e: any) { threw = e.message; }
  check("the requester cannot accept their own request", /only the counterparty/.test(threw));
  threw = ""; try { R.applySwapAction("swap_accept", { id: req.id }, null, cfg, st.swaps, now); } catch (e: any) { threw = e.message; }
  check("no identity → nothing is allowed", /identity could not be established/.test(threw));
  st = R.applySwapAction("swap_accept", { id: req.id }, eng1, cfg, st.swaps, now);
  check("accepted by the counterparty", st.swap.status === "accepted" && st.swap.decided_by?.email === "eng1@x");
  const oct5 = R.coverFor("oncall", "2026-10-05", S, st.swaps, now.ms), sep14 = R.coverFor("oncall", "2026-09-14", Z, st.swaps, now.ms);
  check("effective: Oct 5 → <ENGINEER_1>, Sep 14 → <ENGINEER_5> (the exchange)", oct5.holder.ext === "1001" && oct5.via?.id === req.id && sep14.holder.ext === "1005");
  check("BASE ROTATION UNCHANGED: pool identical, pickRoster still says <ENGINEER_5> for Oct 5 and <ENGINEER_1> for Sep 14", JSON.stringify(cfg.oncall.pool) === poolSnapshot && R.pickRoster(cfg.oncall.pool, cfg.oncall.anchor, "2026-10-05").ext === "1005" && R.pickRoster(cfg.oncall.pool, cfg.oncall.anchor, "2026-09-14").ext === "1001");
  check("the cycle is not reordered: Nov 2 (next <ENGINEER_5> week) still <ENGINEER_5>, Oct 12 still <ENGINEER_1>", R.coverFor("oncall", "2026-11-02", R.pickRoster(cfg.oncall.pool, cfg.oncall.anchor, "2026-11-02"), st.swaps, now.ms).holder.ext === "1005" && R.coverFor("oncall", "2026-10-12", R.pickRoster(cfg.oncall.pool, cfg.oncall.anchor, "2026-10-12"), st.swaps, now.ms).holder.ext === "1001");
  const built = R.buildOncall(now, cfg.oncall, 4, st.swaps);
  check("buildOncall reports holder, base and swap id per week", built.upcoming[3].week_start === "2026-10-05" && built.upcoming[3].ext === "1001" && built.upcoming[3].base.ext === "1005" && built.upcoming[3].swap_id === req.id);

  // overlapping: the week already moved on
  threw = ""; try { R.applySwapAction("swap_request", { kind: "oncall", period: "2026-10-05", counterparty_ext: "1003" }, eng5, cfg, st.swaps, now); } catch (e: any) { threw = e.message; }
  check("overlap: <ENGINEER_5> cannot give away Oct 5 again — <ENGINEER_1> holds it now", /you do not hold Mon 2026-10-05; <ENGINEER_1> does/.test(threw));
  const st2 = R.applySwapAction("swap_request", { kind: "oncall", period: "2026-10-05", counterparty_ext: "1002" }, eng1, cfg, st.swaps, now);
  check("the new holder can pass it on (chain)", st2.swap.status === "pending" && st2.swap.from.ext === "1001");
  threw = ""; try { R.applySwapAction("swap_request", { kind: "oncall", period: "2026-10-05", counterparty_ext: "1003" }, eng1, cfg, st2.swaps, now); } catch (e: any) { threw = e.message; }
  check("a week with a pending request refuses a second one", /already pending/.test(threw));
  const st3 = R.applySwapAction("swap_accept", { id: st2.swap.id }, eng2, cfg, st2.swaps, now);
  check("chained accept: Oct 5 → <ENGINEER_2>, applied in decision order", R.coverFor("oncall", "2026-10-05", S, st3.swaps, now.ms).holder.ext === "1002");
  // a stale accepted swap whose giver no longer holds the week is skipped, not stacked
  const stale = { ...req, id: "stale", status: "accepted" as const, from: req.from, to: { ...req.to, name: "<ENGINEER_3>", ext: "1003", email: "eng3@x" }, decided_at: "2026-09-10T21:00:00.000Z" };
  const c = R.coverFor("oncall", "2026-10-05", S, [...st3.swaps, stale], now.ms);
  check("an accepted swap from someone who no longer holds the week is skipped and reported", c.holder.ext === "1002" && c.skipped.length === 1 && c.skipped[0].id === "stale");

  // decline and cancel
  const d1 = R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-14", counterparty_ext: "1003" }, eng5, cfg, st3.swaps, now);
  threw = ""; try { R.applySwapAction("swap_cancel", { id: d1.swap.id }, eng3, cfg, d1.swaps, now); } catch (e: any) { threw = e.message; }
  check("only the requester can cancel", /only the requester, <ENGINEER_5>/.test(threw));
  const d2 = R.applySwapAction("swap_decline", { id: d1.swap.id }, eng3, cfg, d1.swaps, now);
  check("declined leaves the roster unchanged", d2.swap.status === "declined" && R.coverFor("oncall", "2026-09-14", Z, d2.swaps, now.ms).holder.ext === "1005");
  threw = ""; try { R.applySwapAction("swap_accept", { id: d1.swap.id }, eng3, cfg, d2.swaps, now); } catch (e: any) { threw = e.message; }
  check("a decided request cannot be decided again", /is declined, not pending/.test(threw));

  // validation edges
  threw = ""; try { R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-07", counterparty_ext: "1001" }, eng5, cfg, [], now); } catch (e: any) { threw = e.message; }
  check("the current week can no longer be swapped whole: its Monday has ended", /can no longer be swapped: Mon 2026-09-07 has ended/.test(threw));
  threw = ""; try { R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-21", counterparty_ext: "1001" }, eng5, cfg, [], now); } catch (e: any) { threw = e.message; }
  check("cannot give away a week you do not hold", /you do not hold Mon 2026-09-21; <ENGINEER_2> does/.test(threw));
  threw = ""; try { R.applySwapAction("swap_request", { kind: "oncall", period: "2026-10-05", counterparty_ext: "1005" }, eng5, cfg, [], now); } catch (e: any) { threw = e.message; }
  check("cannot swap with yourself", /cannot swap with yourself/.test(threw));
  threw = ""; try { R.applySwapAction("swap_request", { kind: "oncall", period: "2026-10-05", counterparty_ext: "1001" }, { agent_id: 5, name: "<ENGINEER_6>", email: "eng6@x", ext: "1006" }, cfg, [], now); } catch (e: any) { threw = e.message; }
  check("a non-member cannot request", /not a member of this rotation/.test(threw));
  threw = ""; try { R.applySwapAction("swap_request", { kind: "oncall", period: "2026-10-05", counterparty_ext: "1001", exchange: "2026-09-21" }, eng5, cfg, [], now); } catch (e: any) { threw = e.message; }
  check("exchange must be a week the counterparty holds", /<ENGINEER_1> does not hold Mon 2026-09-21; <ENGINEER_2> does/.test(threw));

  // expiry
  const old = { ...req, id: "old", period: "2026-09-07", exchange: null, status: "pending" as const, decided_at: null, decided_by: null };
  check("a pending whole-week request is expired once its Monday has ended", R.swapStatus(old, now.ms) === "expired");
  threw = ""; try { R.applySwapAction("swap_accept", { id: "old" }, eng1, cfg, [old], now); } catch (e: any) { threw = e.message; }
  check("an expired request cannot be accepted", /is expired, not pending/.test(threw));

  // Saturday: single approver
  const eng8 = { agent_id: 2, name: "<ENGINEER_8>", email: "eng8@x", ext: "1008" }, eng7 = { agent_id: 3, name: "<ENGINEER_7>", email: "eng7@x", ext: "1007" };
  const s1 = R.applySwapAction("swap_request", { kind: "swing", period: "2026-09-12", counterparty_ext: "1007", exchange: "2026-09-19" }, eng8, cfg, [], now);
  check("Saturday requests ignore exchange (single-period cover)", s1.swap.kind === "swing" && s1.swap.exchange === null);
  threw = ""; try { R.applySwapAction("swap_accept", { id: s1.swap.id }, eng7, cfg, s1.swaps, now); } catch (e: any) { threw = e.message; }
  check("the counterparty cannot approve a Saturday swap", /only the Saturday approver, <ENGINEER_4>/.test(threw));
  threw = ""; try { R.applySwapAction("swap_accept", { id: s1.swap.id }, eng8, cfg, s1.swaps, now); } catch (e: any) { threw = e.message; }
  check("nor can the requester", /only the Saturday approver/.test(threw));
  threw = ""; try { R.applySwapAction("swap_accept", { id: s1.swap.id }, eng4, cfg, s1.swaps, now); } catch (e: any) { threw = e.message; }
  check("Saturday approval without a reason is refused", /a reason is required to approve a Saturday swap/.test(threw));
  threw = ""; try { R.applySwapAction("swap_decline", { id: s1.swap.id, reason: "   " }, eng4, cfg, s1.swaps, now); } catch (e: any) { threw = e.message; }
  check("a blank reason does not count", /a reason is required to decline a Saturday swap/.test(threw));
  const s2 = R.applySwapAction("swap_accept", { id: s1.swap.id, reason: "<ENGINEER_7> confirmed he is free" }, eng4, cfg, s1.swaps, now);
  check("the reason is stored on the Saturday record", s2.swap.decided_reason === "<ENGINEER_7> confirmed he is free" && s2.swap.status === "accepted");
  const sat = R.buildSwing(now, cfg.swing, 4, s2.swaps);
  check("approved by <ENGINEER_4>: Sep 12 → <ENGINEER_7>, base still <ENGINEER_8>, Sep 19 untouched", sat.saturdays[0].date === "2026-09-12" && sat.saturdays[0].ext === "1007" && sat.saturdays[0].base.ext === "1008" && sat.saturdays[1].ext === "1009");
  const noApprover = { ...cfg, swing: { ...cfg.swing, approver: null } };
  threw = ""; try { R.authorizeDecision(s1.swap, eng4, "accept", noApprover, now.ms); } catch (e: any) { threw = e.message; }
  check("with no approver configured nobody can approve", /no Saturday swap approver is set/.test(threw));
  // the drift check follows the EFFECTIVE on-call
  const acc = R.applySwapAction("swap_accept", { id: req.id }, eng1, cfg, [req], now).swaps;
  const nowOct = et("2026-10-07T15:00:00Z");
  const eff = R.buildOncall(nowOct, cfg.oncall, 4, acc);
  check("in the swapped week the drift check expects the covering person", eff.current.week_start === "2026-10-05" && eff.current.ext === "1001" && eff.current.base.ext === "1005");
  check("viewerRoles: <ENGINEER_4> is approver, not a member; <ENGINEER_1> is an on-call member", R.viewerRoles(eng4, cfg).swing_approver === true && R.viewerRoles(eng4, cfg).oncall_member === null && R.viewerRoles(eng1, cfg).oncall_member?.ext === "1001");
}

console.log("shift-start checklist: a server-side record");
{
  const cfg = R.resolveConfig({
    swing: { pool: [{ name: "<ENGINEER_7>", ext: "1007", email: "engineer7@example.com" }, { name: "<ENGINEER_8>", ext: "1008", email: "engineer8@example.com" }, { name: "<ENGINEER_9>", ext: "1009", email: "engineer9@example.com" }], anchor: "2026-09-05", approver: { name: "<ENGINEER_4>", ext: "1004", email: "engineer4@example.com" } },
  }).cfg;
  const total = R.SWING.checklist.length;
  const eng8 = { agent_id: 17, name: "<ENGINEER_8>", email: "engineer8@example.com", ext: null };
  const eng7 = { agent_id: 14, name: "<ENGINEER_7>", email: "engineer7@example.com", ext: null };
  const eng4 = { agent_id: 15, name: "<ENGINEER_4>", email: "engineer4@example.com", ext: null };
  const sat = "2026-09-12";   // <ENGINEER_8>'s Saturday (pool[1], one week after the anchor)
  const holder = R.pickRoster(cfg.swing.pool, cfg.swing.anchor, sat);
  check("Sep 12 is <ENGINEER_8>'s", holder.ext === "1008");
  const t = (iso: string) => Date.parse(iso);
  check("window: closed before 8:00 AM Saturday ET", R.chkWindow(sat, t("2026-09-12T11:59:00Z")) === "not_open");
  check("window: open from 8:00 AM Saturday ET", R.chkWindow(sat, t("2026-09-12T12:00:00Z")) === "open");
  check("window: still open Sunday and early Monday", R.chkWindow(sat, t("2026-09-13T20:00:00Z")) === "open" && R.chkWindow(sat, t("2026-09-14T11:59:00Z")) === "open");
  check("window: closed from Monday 8:00 AM ET", R.chkWindow(sat, t("2026-09-14T12:00:00Z")) === "closed");
  const threw = (fn: () => any) => { try { fn(); return ""; } catch (e: any) { return String(e.message); } };
  check("no identity → refused", /identity could not be established/.test(threw(() => R.applyTick(null, sat, holder, null, 1, true, t("2026-09-12T12:14:00Z"), total))));
  check("<ENGINEER_7> (another member) cannot tick <ENGINEER_8>'s Saturday", /only <ENGINEER_8>, who covers Sat 2026-09-12/.test(threw(() => R.applyTick(null, sat, holder, eng7, 1, true, t("2026-09-12T12:14:00Z"), total))));
  check("<ENGINEER_4> (approver) cannot tick either — view only", /only <ENGINEER_8>/.test(threw(() => R.applyTick(null, sat, holder, eng4, 1, true, t("2026-09-12T12:14:00Z"), total))));
  check("<ENGINEER_8> before 8:00 AM → not open", /opens at 08:00/.test(threw(() => R.applyTick(null, sat, holder, eng8, 1, true, t("2026-09-12T11:00:00Z"), total))));
  check("<ENGINEER_8> on Tuesday → closed, record stays", /closed Monday 08:00/.test(threw(() => R.applyTick(null, sat, holder, eng8, 1, true, t("2026-09-15T12:00:00Z"), total))));
  check("item out of range refused", /item must be 1\.\.5/.test(threw(() => R.applyTick(null, sat, holder, eng8, 7, true, t("2026-09-12T12:14:00Z"), total))));
  let store = R.applyTick(null, sat, holder, eng8, 1, true, t("2026-09-12T12:14:03Z"), total);
  store = R.applyTick(store, sat, holder, eng8, 3, true, t("2026-09-12T12:20:00Z"), total);
  store = R.applyTick(store, sat, holder, eng8, 2, true, t("2026-09-12T18:30:00Z"), total);   // 2:30 PM — after the shift
  const rec = R.chkRecord(store, sat, "1008");
  check("record keyed per Saturday per tech, a timestamp on each tick", rec?.ticks["1"] === "2026-09-12T12:14:03.000Z" && rec?.ticks["3"] === "2026-09-12T12:20:00.000Z" && Object.keys(store.saturdays).length === 1 && Object.keys(store.saturdays[sat]).length === 1);
  const sum = R.chkSummary(rec, total, sat);
  check("summary: 3/5, last tick time, one late (after 1:00 PM)", sum.done === 3 && sum.last_at === "2026-09-12T18:30:00.000Z" && sum.late === 1);
  store = R.applyTick(store, sat, holder, eng8, 3, false, t("2026-09-12T12:21:00Z"), total);
  check("untick removes the item and its time", !R.chkRecord(store, sat, "1008")?.ticks["3"] && R.chkSummary(R.chkRecord(store, sat, "1008"), total, sat).done === 2);
  check("another Saturday's record is separate and empty", R.chkSummary(R.chkRecord(store, "2026-09-19", "1009"), total, "2026-09-19").done === 0);
  // Swap: <ENGINEER_7> covers <ENGINEER_8>'s Saturday → <ENGINEER_7> can tick it, <ENGINEER_8> no longer can.
  const swap = { id: "s1", kind: "swing", period: sat, exchange: null, from: { agent_id: 17, name: "<ENGINEER_8>", email: "engineer8@example.com", ext: "1008" }, to: { agent_id: 14, name: "<ENGINEER_7>", email: "engineer7@example.com", ext: "1007" }, note: "", status: "accepted", requested_at: "2026-09-10T00:00:00Z", decided_at: "2026-09-10T01:00:00Z", decided_by: null };
  const eff = R.coverFor("swing", sat, holder, [swap], t("2026-09-12T12:00:00Z")).holder;
  check("after an accepted swap the effective holder ticks, not the base holder", eff.ext === "1007" && /only <ENGINEER_7>/.test(threw(() => R.applyTick(null, sat, eff, eng8, 1, true, t("2026-09-12T12:14:00Z"), total))) && !threw(() => R.applyTick(null, sat, eff, eng7, 1, true, t("2026-09-12T12:14:00Z"), total)));
  // History as a manager sees it on Thu Sep 17: Sep 12 (<ENGINEER_8>, 2 ticks, no PSA actions) and Sep 5 (<ENGINEER_7>, 155 actions, no ticks); Aug 29 is before the anchor with no record → not listed, counted.
  const activity = [{ date: "2026-09-05", agent_id: 14, actions: 155, tickets: 17, first_at: "2026-09-05T12:05:00.000Z", last_at: "2026-09-05T15:50:00.000Z" }];
  const agentOf = (p: any) => ({ "engineer7@example.com": 14, "engineer8@example.com": 17, "engineer9@example.com": 18 } as any)[p.email] ?? null;
  // History reads the coverage record; main() freezes before it reads, so the tests do the same.
  const cov1 = R.freezeCoverage(null, cfg.swing, [], et("2026-09-17T20:00:00Z"), store, agentOf, "t1", 21).store;
  const hist = R.buildHistory(et("2026-09-17T20:00:00Z"), cfg.swing, [], store, activity, agentOf, 21, cov1);
  check("history: most recent first; Aug 29 (before effective_from, no record) is not listed (21 days → two rows)", eq(hist.map((h: any) => h.date), ["2026-09-12", "2026-09-05"]));
  check("Sep 12: <ENGINEER_8>, 2/5, no PSA actions → ticked · no PSA actions", hist[0].name === "<ENGINEER_8>" && hist[0].done === 2 && hist[0].actions === 0 && hist[0].flag === "no_actions");
  check("Sep 5: <ENGINEER_7>, 155 actions / 17 tickets 08:05–11:50, 0/5 → worked · no ticks", hist[1].actions === 155 && hist[1].tickets === 17 && hist[1].first_action === "2026-09-05T12:05:00.000Z" && hist[1].flag === "no_ticks");
  check("Aug 29 is counted as omitted, with its date", eq(R.historyOmitted(et("2026-09-17T20:00:00Z"), cfg.swing, cov1, 21), { count: 1, first: "2026-08-29", last: "2026-08-29" }));
  const cov2 = R.freezeCoverage(null, cfg.swing, [], et("2026-09-24T20:00:00Z"), store, agentOf, "t2", 7).store;
  const hist2 = R.buildHistory(et("2026-09-24T20:00:00Z"), cfg.swing, [], store, activity, agentOf, 7, cov2);
  check("Sep 19: <ENGINEER_9> assigned, 0/5, no actions → NO EVIDENCE (the finding that matters)", hist2[0].date === "2026-09-19" && hist2[0].flag === "no_evidence");
  const cov3 = R.freezeCoverage(null, cfg.swing, [], et("2026-09-24T20:00:00Z"), store, () => null, "t3", 7).store;
  const hist3 = R.buildHistory(et("2026-09-24T20:00:00Z"), cfg.swing, [], store, activity, () => null, 7, cov3);
  check("no PSA agent matched → unmatched, never no_evidence", hist3[0].flag === "unmatched" && hist3[0].actions === null);
  check("today's Saturday joins history only once its shift is over", R.buildHistory(et("2026-09-12T15:00:00Z"), cfg.swing, [], store, activity, agentOf, 7)[0].date === "2026-09-05" && R.buildHistory(et("2026-09-12T17:30:00Z"), cfg.swing, [], store, activity, agentOf, 7)[0].date === "2026-09-12");
}

console.log("Saturday history: the holder is a snapshot, never recomputed; swing.effective_from");
{
  const six = [{ name: "<ENGINEER_7>", ext: "1007", email: "engineer7@example.com" }, { name: "<ENGINEER_8>", ext: "1008", email: "engineer8@example.com" }, { name: "<ENGINEER_9>", ext: "1009", email: "engineer9@example.com" },
    { name: "<ENGINEER_10>", ext: "1010", email: "engineer10@example.com" }, { name: "<ENGINEER_11>", ext: "1011", email: "engineer11@example.com" }, { name: "<ENGINEER_12>", ext: "1012", email: "engineer12@example.com" }];
  const old = R.resolveConfig({ swing: { pool: six, anchor: "2026-09-05", approver: { name: "<ENGINEER_4>", ext: "1004" } } }).cfg;
  check("effective_from defaults to the anchor", old.swing.effective_from === "2026-09-05");
  const ef = R.resolveConfig({ swing: { pool: six, anchor: "2026-10-03", effective_from: "2026-09-12", approver: null } });
  check("effective_from is stored when given; a bad one is reported and falls back to the anchor", ef.cfg.swing.effective_from === "2026-09-12" && ef.problems.length === 0
    && R.resolveConfig({ swing: { pool: six, anchor: "2026-10-03", effective_from: "soon" } }).cfg.swing.effective_from === "2026-10-03" && /effective_from must be YYYY-MM-DD/.test(R.resolveConfig({ swing: { pool: six, anchor: "2026-10-03", effective_from: "soon" } }).problems[0]));
  const agentOf = (p: any) => ({ "engineer7@example.com": 14, "engineer8@example.com": 17 } as any)[p.email] ?? null;
  const activity = [{ date: "2026-09-05", agent_id: 14, actions: 155, tickets: 17, first_at: "2026-09-05T12:05:00.000Z", last_at: "2026-09-05T15:50:00.000Z" }];
  // Thu Sep 10 under the old roster: Sep 5 has passed → moment (1) freezes it as <ENGINEER_7> (roster). Aug 29 is before effective_from → not frozen.
  const now1 = et("2026-09-10T20:00:00Z");
  check("passedSaturdays: most recent first, today's only after its shift", eq(R.passedSaturdays(now1, 21), ["2026-09-05", "2026-08-29", "2026-08-22"]) && R.passedSaturdays(et("2026-09-12T15:00:00Z"), 7)[0] === "2026-09-05" && R.passedSaturdays(et("2026-09-12T17:30:00Z"), 7)[0] === "2026-09-12");
  let fz = R.freezeCoverage(null, old.swing, [], now1, null, agentOf, "job-1", 21);
  check("moment (1): Sep 5 frozen as <ENGINEER_7> from the roster; Aug 29 / Aug 22 not frozen (before this roster)", eq(fz.frozen, ["2026-09-05"]) && fz.store.saturdays["2026-09-05"].name === "<ENGINEER_7>" && fz.store.saturdays["2026-09-05"].source === "roster" && fz.store.saturdays["2026-09-05"].agent_id === 14 && fz.store.saturdays["2026-09-05"].job_id === "job-1");
  const again = R.freezeCoverage(fz.store, old.swing, [], now1, null, agentOf, "job-2", 21);
  check("idempotent: a recorded Saturday is never overwritten", again.frozen.length === 0 && again.store.saturdays["2026-09-05"].job_id === "job-1");
  // The new seven-person roster anchored Oct 3, applying from Sep 12 — history must still read Sep 5 as <ENGINEER_7>.
  const seven = [six[2], six[0], six[1], { name: "<ENGINEER_13>", ext: "1013", email: "engineer13@example.com" }, six[3], six[4], six[5]];
  const neu = R.resolveConfig({ swing: { pool: seven, anchor: "2026-10-03", effective_from: "2026-09-12", approver: null } }).cfg;
  check("the new cycle alone would say <ENGINEER_13> for Sep 5 (the bug)", R.pickRoster(neu.swing.pool, neu.swing.anchor, "2026-09-05").name === "<ENGINEER_13>");
  const h = R.buildHistory(now1, neu.swing, [], null, activity, agentOf, 21, fz.store);
  check("history reads the record: Sep 5 is <ENGINEER_7> (source record), judged worked · no ticks", h[0].date === "2026-09-05" && h[0].name === "<ENGINEER_7>" && h[0].recorded && h[0].source === "record" && h[0].flag === "no_ticks" && h[0].actions === 155);
  check("Saturdays before effective_from with no record are not listed; the omitted count names the range", h.length === 1 && eq(R.historyOmitted(now1, neu.swing, fz.store, 21), { count: 2, first: "2026-08-22", last: "2026-08-29" }));
  const bf = { saturdays: { "2026-08-29": { ...fz.store.saturdays["2026-09-05"], name: "<ENGINEER_8>", ext: "1008", email: "engineer8@example.com", source: "backfill", reason: "seeded from PSA evidence" } } };
  const hbf = R.buildHistory(now1, neu.swing, [], null, activity, agentOf, 21, bf);
  check("a backfilled Saturday before effective_from shows in full and is not counted as omitted", hbf.length === 1 && hbf[0].date === "2026-08-29" && hbf[0].name === "<ENGINEER_8>" && hbf[0].source === "backfill" && hbf[0].recorded && R.historyOmitted(now1, neu.swing, bf, 21).count === 2);
  const h0 = R.buildHistory(now1, neu.swing, [], null, activity, agentOf, 21, null);
  check("without any record Sep 5 is not listed at all — never shown as <ENGINEER_13> — and the omitted count is three", h0.length === 0 && eq(R.historyOmitted(now1, neu.swing, null, 21), { count: 3, first: "2026-08-22", last: "2026-09-05" }));
  // After effective_from with no record → recomputed and NOT judged.
  const now2 = et("2026-09-17T20:00:00Z");
  const h2 = R.buildHistory(now2, neu.swing, [], null, [], agentOf, 7, null);
  check("Sep 12 passed with no record → recomputed (<ENGINEER_10>), never no_evidence", h2[0].date === "2026-09-12" && h2[0].name === "<ENGINEER_10>" && h2[0].source === "recomputed" && h2[0].flag === "recomputed");
  // Moment (3): a checklist record wins — even over the roster of the day.
  const store = R.applyTick(null, "2026-09-12", { name: "<ENGINEER_10>", ext: "1010", email: "engineer10@example.com" }, { agent_id: 1, name: "<ENGINEER_10>", email: "engineer10@example.com", ext: null }, 1, true, Date.parse("2026-09-12T12:14:00Z"), 5);
  const fz3 = R.freezeCoverage(null, { ...neu.swing, pool: seven.filter(p => p.ext !== "1010") }, [], now2, store, agentOf, "job-3", 7);
  check("checklist record wins: Sep 12 recorded as <ENGINEER_10> from the ticks although the roster no longer names him", fz3.store.saturdays["2026-09-12"]?.name === "<ENGINEER_10>" && fz3.store.saturdays["2026-09-12"].source === "checklist");
  const backfill = { saturdays: { "2026-09-05": { name: "<ENGINEER_7>", email: "engineer7@example.com", ext: "1007", rc_id: null, agent_id: null, base_name: "<ENGINEER_7>", swap_id: null, swap_reason: null, source: "backfill", recorded_at: "2026-09-11T20:00:00Z", job_id: null, reason: "PSA: 155 actions on 17 tickets" } } };
  const hb = R.buildHistory(now1, neu.swing, [], null, activity, agentOf, 7, backfill);
  check("a backfill record reads as <ENGINEER_7> with its reason, agent id resolved by email when the record has none", hb[0].name === "<ENGINEER_7>" && hb[0].source === "backfill" && hb[0].reason === "PSA: 155 actions on 17 tickets" && hb[0].agent_id === 14 && hb[0].flag === "no_ticks");
}

console.log("roster candidates: PSA agent ∩ RingCentral extension");
{
  const agents = [{ agent_id: 1, name: "<ENGINEER_8>", email: "engineer8@example.com" }, { agent_id: 2, name: "<ENGINEER_2>", email: "engineer2@example.com" }, { agent_id: 3, name: "PSA Only", email: "psa.only@example.com" }, { agent_id: 4, name: "Name Match", email: null }];
  const exts = R.normalizeRcExtensions({ records: [
    { id: "<RC_ID_8>", extensionNumber: "1008", name: "<ENGINEER_8>", contact: { email: "engineer8@example.com" }, status: "Enabled", type: "User" },
    { id: "<RC_ID_2>", extensionNumber: "1002", name: "<ENGINEER_2>", contact: { email: "Engineer2@example.com" }, status: "Enabled", type: "User" },
    { id: 5, extensionNumber: "555", name: "Name Match", contact: { email: "name.match@example.com" }, status: "Enabled", type: "User" },
    { id: 6, extensionNumber: "888", name: "Front Desk", contact: { email: "frontdesk@example.com" }, status: "Enabled", type: "User" },
    { id: 7, extensionNumber: "700", name: "Old Timer", contact: {}, status: "Disabled", type: "User" },
    { id: 8, extensionNumber: "701", name: "Conference", contact: {}, status: "Enabled", type: "Department" },
  ] });
  check("disabled and non-user extensions are dropped", eq(exts.map((e: any) => e.ext), ["1008", "1002", "555", "888"]));
  const c = R.matchPeople(agents, exts);
  const by = (n: string) => c.find((x: any) => x.name === n);
  check("email match, case-folded: <ENGINEER_2> gets ext, rc_id and the lower-cased email", by("<ENGINEER_2>").ok && by("<ENGINEER_2>").ext === "1002" && by("<ENGINEER_2>").rc_id === "<RC_ID_2>" && by("<ENGINEER_2>").email === "engineer2@example.com" && by("<ENGINEER_2>").via === "email");
  check("name match when PSA has no email: takes RingCentral's email", by("Name Match").ok && by("Name Match").via === "name" && by("Name Match").email === "name.match@example.com");
  check("PSA-only agent cannot be added, and says why", !by("PSA Only").ok && /no RingCentral extension/.test(by("PSA Only").why));
  check("RingCentral-only extension cannot be added, and says why", !by("Front Desk").ok && by("Front Desk").agent_id === null && /no PSA agent/.test(by("Front Desk").why));
  check("addable people sort first", c.findIndex((x: any) => !x.ok) === 3 && c.slice(0, 3).every((x: any) => x.ok));
}

console.log("Saturday swap notifications: payload only here — the send is best effort and never a blocker");
{
  const s: any = { id: "swing-2026-09-19-x", kind: "swing", period: "2026-09-19", exchange: null, from: { agent_id: 1, name: "<ENGINEER_9>", email: "s@x", ext: "1009" }, to: { agent_id: 2, name: "<ENGINEER_8>", email: "r@x", ext: "1008" }, note: "dentist", status: "pending", requested_at: "2026-09-15T14:00:00.000Z", decided_at: null, decided_by: null, decided_reason: null };
  const ev = R.swapEvent("request", s, { name: "<ENGINEER_4>", ext: "1004" });
  check("request event: the Saturday, requester, cover, approver, and the dashboard link", /Saturday swap request · Sat 2026-09-19/.test(ev.title) && ev.facts.some((f: any) => f.name === "Requested by" && /<ENGINEER_9> \(x1009\)/.test(f.value)) && ev.facts.some((f: any) => f.name === "Covered by" && /<ENGINEER_8>/.test(f.value)) && ev.facts.some((f: any) => f.name === "Approver" && /<ENGINEER_4>/.test(f.value)) && ev.url === R.podUrl(R.DASHBOARD_URL, "swing"));
  const dec: any = { ...s, status: "declined", decided_at: "2026-09-15T15:00:00.000Z", decided_by: { name: "<ENGINEER_4>", ext: "1004", email: "c@x", agent_id: 9 }, decided_reason: "<ENGINEER_8> is already covering Sep 12" };
  const ev2 = R.swapEvent("decision", dec, null);
  check("decision event carries the verb, the decider and the reason", /Saturday swap declined/.test(ev2.title) && ev2.facts.some((f: any) => f.name === "Reason" && f.value === "<ENGINEER_8> is already covering Sep 12") && /declined by <ENGINEER_4>: <ENGINEER_8> is already covering Sep 12/.test(ev2.summary));
  const card = R.adaptiveCard(ev);
  check("Power Automate envelope: message + one Adaptive Card 1.4 with an OpenUrl action to the dashboard", card.type === "message" && card.attachments[0].contentType === "application/vnd.microsoft.card.adaptive" && card.attachments[0].content.version === "1.4" && card.attachments[0].content.actions[0].type === "Action.OpenUrl" && card.attachments[0].content.actions[0].url === R.podUrl(R.DASHBOARD_URL, "swing"));
  check("n8n / generic payload carries the plain event plus the card", R.notifyPayload("n8n", ev).event === "request" && R.notifyPayload("n8n", ev).card.type === "message" && R.notifyPayload("power_automate", ev).type === "message");
  const pa = R.notifyPayload("power_automate", ev);
  check("Power Automate payload also carries the event fields at top level, so a flow can route on recipients[0].email", pa.recipients?.[0]?.email === undefined ? false : pa.recipients[0].role === "approver" && pa.event === "request" && pa.kind === "swing" && pa.url === R.podUrl(R.DASHBOARD_URL, "swing") && Array.isArray(pa.attachments) && pa.attachments[0].content.type === "AdaptiveCard");
  check("Saturday recipients: request and cancel → the approver; decision → the requester", ev.recipients[0]?.role === "approver" && ev.recipients[0]?.name === "<ENGINEER_4>" && ev2.recipients[0]?.role === "requester" && ev2.recipients[0]?.name === "<ENGINEER_9>" && R.swapEvent("cancel", { ...s, status: "cancelled", decided_at: "2026-09-15T16:00:00Z", decided_by: s.from }, { name: "<ENGINEER_4>", ext: "1004" }).recipients[0]?.role === "approver");
  // On-call, mutual consent: request → counterparty, decision → requester, cancel → counterparty.
  const oc: any = { id: "oncall-2026-10-05-x", kind: "oncall", period: "2026-10-05", exchange: "2026-09-14", from: { agent_id: 3, name: "<ENGINEER_5>", email: "sc@x", ext: "1005" }, to: { agent_id: 0, name: "<ENGINEER_1>", email: "z@x", ext: "1001" }, note: "family trip", status: "pending", requested_at: "2026-09-10T20:00:00.000Z", decided_at: null, decided_by: null, decided_reason: null };
  const o1 = R.swapEvent("request", oc, null);
  check("on-call request → the counterparty, with the exchange offered and the note", o1.recipients[0]?.role === "counterparty" && o1.recipients[0]?.name === "<ENGINEER_1>" && /On-call swap request · week of Mon 2026-10-05/.test(o1.title) && o1.facts.some((f: any) => f.name === "In exchange for" && /2026-09-14/.test(f.value)) && o1.facts.some((f: any) => f.name === "Note" && f.value === "family trip") && /offering the week of Mon 2026-09-14 in return/.test(o1.summary));
  const o2 = R.swapEvent("decision", { ...oc, status: "accepted", decided_at: "2026-09-10T21:00:00Z", decided_by: oc.to, decided_reason: null }, null);
  check("on-call decision → the requester; no reason reads 'none given'", o2.recipients[0]?.role === "requester" && o2.recipients[0]?.name === "<ENGINEER_5>" && /On-call swap accepted/.test(o2.title) && o2.facts.some((f: any) => f.name === "Reason" && f.value === "none given"));
  const o3 = R.swapEvent("cancel", { ...oc, status: "cancelled", decided_at: "2026-09-10T21:00:00Z", decided_by: oc.from }, null);
  check("on-call cancel → the counterparty, worded as a withdrawal", o3.recipients[0]?.role === "counterparty" && /request withdrawn/.test(o3.title) && /nothing is waiting on you/.test(o3.summary));
  check("the card names who it is for", /For <ENGINEER_1> \(counterparty\)/.test(JSON.stringify(R.adaptiveCard(o1))));
}

console.log("day-range swaps (phase 2)");
{
  const threw = (f: () => any): string => { try { f(); return ""; } catch (e: any) { return String(e?.message || e); } };
  const party = (p: any) => ({ agent_id: null, name: p.name, email: p.email ?? null, ext: p.ext, rc_id: p.rc_id ?? null });
  const base = (day: string) => R.pickRoster(D.oncall.pool, D.oncall.anchor, R.mondayOf(day));
  const wed = et("2026-09-09T15:00:00Z");                    // Wed Sep 9; the week of Sep 14 is <ENGINEER_1>'s
  const fri = { id: "d1", kind: "oncall", week_start: "2026-09-14", covers: { from: "2026-09-18", to: "2026-09-19" }, exchange: null, from: party(eng1), to: party(eng2), note: "",
    status: "accepted", requested_at: "2026-09-09T14:00:00.000Z", decided_at: "2026-09-09T14:30:00.000Z", decided_by: party(eng2) };
  check("rangeLabel: whole week, one day, a run, a Saturday", R.rangeLabel("oncall", "2026-09-14", R.wholeWeek("2026-09-14")) === "week of Mon 2026-09-14" && R.rangeLabel("oncall", "2026-09-14", fri.covers) === "Fri 2026-09-18"
    && R.rangeLabel("oncall", "2026-09-14", { from: "2026-09-16", to: "2026-09-19" }) === "Wed 2026-09-16 – Fri 2026-09-18" && R.rangeLabel("swing", "2026-09-12", { from: "2026-09-12", to: "2026-09-13" }) === "Sat 2026-09-12");
  const legacy = R.normSwap({ id: "L", kind: "oncall", period: "2026-10-12", exchange: "2026-11-16", from: party(eng1), to: party(eng2), note: "", status: "accepted", requested_at: "x", decided_at: "2026-09-01T00:00:00.000Z", decided_by: party(eng2) });
  check("normSwap: a legacy row's period becomes a whole-week range and its exchange string a week", legacy.week_start === "2026-10-12" && R.isWholePeriod("oncall", legacy.week_start, legacy.covers) && legacy.exchange?.week_start === "2026-11-16" && legacy.exchange?.covers.to === "2026-11-23" && !("period" in legacy));
  check("holderOn: Friday moves to <ENGINEER_2>, Thursday and Saturday stay with <ENGINEER_1>", R.holderOn("oncall", "2026-09-18", base("2026-09-18"), [fri], wed.ms).holder.ext === eng2.ext && R.holderOn("oncall", "2026-09-17", base("2026-09-17"), [fri], wed.ms).holder.ext === eng1.ext && R.holderOn("oncall", "2026-09-19", base("2026-09-19"), [fri], wed.ms).holder.ext === eng1.ext);
  const runs = R.weekRuns("2026-09-14", base("2026-09-14"), [fri], wed.ms);
  check("weekRuns: Mon–Thu <ENGINEER_1> · Fri <ENGINEER_2> · Sat–Sun <ENGINEER_1>", eq(runs.map((r: any) => [r.from, r.days, r.ext, r.swap_id]), [["2026-09-14", 4, eng1.ext, null], ["2026-09-18", 1, eng2.ext, "d1"], ["2026-09-19", 2, eng1.ext, null]]));
  const oc = R.buildOncall(wed, D.oncall, 4, [fri]);
  const w14 = oc.upcoming.find((w: any) => w.week_start === "2026-09-14");
  check("buildOncall: the week is split, its headline is Monday's holder, the whole-week swap mark is off; unsplit weeks have one run", w14.split && w14.name === eng1.name && w14.swap_id === null && w14.runs.length === 3 && oc.upcoming.filter((w: any) => w.week_start !== "2026-09-14").every((w: any) => !w.split && w.runs.length === 1));
  const friNow = et("2026-09-18T15:00:00Z");
  check("the current week's headline is TODAY's holder: on Friday Sep 18 it is <ENGINEER_2>, and oncall.today says so", R.buildOncall(friNow, D.oncall, 4, [fri]).current.name === eng2.name && R.buildOncall(friNow, D.oncall, 4, [fri]).today.ext === eng2.ext && R.buildOncall(et("2026-09-17T15:00:00Z"), D.oncall, 4, [fri]).current.name === eng1.name);
  // requests through the real state machine
  const me = party(eng1), them = party(eng2);
  const r1 = R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-14", counterparty_ext: eng2.ext, covers_from: "2026-09-18", covers_to: "2026-09-19" }, me, R.resolveConfig(null).cfg, [], wed);
  check("a one-day request stores covers [Fri, Sat) inside week_start and an id keyed on the day", r1.swap.week_start === "2026-09-14" && eq(r1.swap.covers, { from: "2026-09-18", to: "2026-09-19" }) && r1.swap.id.startsWith("oncall-2026-09-18-") && r1.swap.status === "pending");
  check("swapStatus: a Friday request stays pending through Friday and expires at the end of it — 23:59:59.999 ET pending, Sat 00:00:00 ET expired", R.swapStatus(r1.swap, et("2026-09-19T03:59:59.999Z").ms) === "pending" && R.swapStatus(r1.swap, et("2026-09-19T04:00:00.000Z").ms) === "expired" && R.swapStatus(r1.swap, et("2026-09-19T12:00:00Z").ms) === "expired" && R.swapStatus(r1.swap, et("2026-09-17T12:00:00Z").ms) === "pending");
  // same-day swaps — the boundary moved to the END of the first covered day (2026-09-12)
  {
    const cfg0 = R.resolveConfig(null).cfg;
    const wedNoon = et("2026-09-09T15:30:00Z");                                 // Wed Sep 9, 11:30 ET; <ENGINEER_5> holds the week of Sep 7
    const sc = party(eng5), ty = party(eng2);
    const todayReq = R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-07", counterparty_ext: eng2.ext, covers_from: "2026-09-09", covers_to: "2026-09-10" }, sc, cfg0, [], wedNoon);
    check("a request for TODAY is accepted while the day is running", todayReq.swap.status === "pending" && todayReq.swap.covers.from === "2026-09-09");
    check("yesterday cannot be swapped: it has ended", /can no longer be swapped: Tue 2026-09-08 has ended/.test(threw(() => R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-07", counterparty_ext: eng2.ext, covers_from: "2026-09-08", covers_to: "2026-09-09" }, sc, cfg0, [], wedNoon))));
    check("a multi-day range starting yesterday is refused on its first day, not its last", /can no longer be swapped: Tue 2026-09-08 has ended/.test(threw(() => R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-07", counterparty_ext: eng2.ext, covers_from: "2026-09-08", covers_to: "2026-09-11" }, sc, cfg0, [], wedNoon))));
    const wedLater = et("2026-09-09T16:12:00Z");                                // 12:12 ET, same day
    const acc = R.applySwapAction("swap_accept", { id: todayReq.swap.id }, ty, cfg0, todayReq.swaps, wedLater);
    check("the counterparty accepts it the same day; today's holder becomes the cover for the rest of the day, tomorrow is untouched", acc.swap.status === "accepted" && R.holderOn("oncall", "2026-09-09", eng5, acc.swaps, wedLater.ms).holder.ext === eng2.ext && R.holderOn("oncall", "2026-09-10", eng5, acc.swaps, wedLater.ms).holder.ext === eng5.ext);
    check("swapView carries when it took effect (the decision time) and when it would have expired (Thu 00:00 ET)", R.swapView(acc.swap, wedLater.ms).effective_at === wedLater.iso && R.swapView(acc.swap, wedLater.ms).expires_at === "2026-09-10T04:00:00.000Z");
    check("a swap accepted before its first day began has no mid-day effective time", R.swapEffectiveAt({ ...acc.swap, decided_at: "2026-09-08T20:00:00.000Z" }) === null);
    const oc = R.buildOncall(wedLater, D.oncall, 4, acc.swaps);
    check("the pod's current week and today carry swap_effective, and the Wednesday run does too", oc.current.swap_id === acc.swap.id && oc.current.swap_effective === wedLater.iso && oc.today.swap_effective === wedLater.iso && oc.current.runs.some((r: any) => r.from === "2026-09-09" && r.effective === wedLater.iso));
    const mp = { ...todayReq.swap, id: "mp", covers: { from: "2026-09-09", to: "2026-09-12" } };
    check("a pending multi-day range expires at the end of its FIRST day", R.swapStatus(mp, et("2026-09-10T03:59:59.999Z").ms) === "pending" && R.swapStatus(mp, et("2026-09-10T04:00:00.000Z").ms) === "expired");
    // Saturday: pending until the shift ends at 1:00 PM ET; approvable while the shift is running
    const sw = R.resolveConfig({ swing: { pool: R.MOCK_SWING, anchor: "2026-09-12" } }).cfg;
    const satReq = R.applySwapAction("swap_request", { kind: "swing", period: "2026-09-12", counterparty_ext: R.MOCK_SWING[1].ext }, party(R.MOCK_SWING[0]), sw, [], et("2026-09-12T13:00:00Z"));   // Sat 09:00 ET, shift running
    check("a Saturday request can be made while the shift is running", satReq.swap.status === "pending");
    check("it stays pending until 1:00 PM ET exactly and is expired from then", R.swapStatus(satReq.swap, et("2026-09-12T16:59:59.999Z").ms) === "pending" && R.swapStatus(satReq.swap, et("2026-09-12T17:00:00.000Z").ms) === "expired");
    const approver = { agent_id: 9, name: sw.swing.approver.name, email: "eng4@x", ext: sw.swing.approver.ext };
    const satAcc = R.applySwapAction("swap_accept", { id: satReq.swap.id, reason: "ok" }, approver, sw, satReq.swaps, et("2026-09-12T14:00:00Z"));   // 10:00 ET
    check("approved mid-shift: effective_at is 10:00 ET and the Saturday row shows it", R.swapView(satAcc.swap, et("2026-09-12T14:00:00Z").ms).effective_at === "2026-09-12T14:00:00.000Z" && R.buildSwing(et("2026-09-12T14:30:00Z"), sw.swing, 4, satAcc.swaps).saturdays[0].swap_effective === "2026-09-12T14:00:00.000Z");
    check("after 1:00 PM a Saturday request is refused: the shift ended", /can no longer be swapped: the shift ended at 13:00/.test(threw(() => R.applySwapAction("swap_request", { kind: "swing", period: "2026-09-12", counterparty_ext: R.MOCK_SWING[1].ext }, party(R.MOCK_SWING[0]), sw, [], et("2026-09-12T17:05:00Z")))));
  }
  check("overlap: a Thu–Fri request is refused while the Friday request is pending", /overlapping Thu 2026-09-17 – Fri 2026-09-18 is already pending \(<ENGINEER_1> → <ENGINEER_2>\)/.test(threw(() => R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext, covers_from: "2026-09-17", covers_to: "2026-09-19" }, me, R.resolveConfig(null).cfg, r1.swaps, wed))));
  check("a range must stay inside its week", /never crosses a week boundary/.test(threw(() => R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext, covers_from: "2026-09-19", covers_to: "2026-09-22" }, me, R.resolveConfig(null).cfg, [], wed))));
  check("a Saturday shift is swapped whole", /swapped whole/.test(threw(() => R.applySwapAction("swap_request", { kind: "swing", period: "2026-09-19", counterparty_ext: R.MOCK_SWING[1].ext, covers_from: "2026-09-19", covers_to: "2026-09-21" }, party(R.MOCK_SWING[0]), R.resolveConfig(null).cfg, [], wed))));
  check("after the Friday swap is accepted, <ENGINEER_1> no longer holds the whole week", /you do not hold Fri 2026-09-18; <ENGINEER_2> does/.test(threw(() => R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext }, me, R.resolveConfig(null).cfg, [fri], wed))));
  check("cross-column overlap: a new request on days another request offers in exchange is refused", !!R.pendingOverlapping("oncall", { from: "2026-11-17", to: "2026-11-18" }, [{ ...legacy, status: "pending", decided_at: null }], wed.ms));
  const ev = R.swapEvent("request", r1.swap, null);
  check("the Teams card for a one-day swap says Days · Fri 2026-09-18, and a whole-week one says Week", ev.facts[0].name === "Days" && ev.facts[0].value === "Fri 2026-09-18" && /cover Fri 2026-09-18\./.test(ev.summary) && R.swapEvent("request", legacy, null).facts[0].name === "Week");
  check("acceptedSorted orders by decision time numerically and normalises legacy rows", R.acceptedSorted("oncall", [fri, { ...legacy, decided_at: "2026-09-10T00:00:00.000Z" }], wed.ms).map((s: any) => s.id).join(",") === "L,d1" || R.acceptedSorted("oncall", [fri, legacy], wed.ms)[0].id === "L");
}

console.log("phase 5: deep links, activity cache, slim polls");
{
  const party = (p: any) => ({ agent_id: null, name: p.name, email: p.email ?? null, ext: p.ext, rc_id: p.rc_id ?? null });
  check("podUrl appends the tab / mode / pod to a URL that already carries the workspace, and to one that does not", R.podUrl("https://x/apps/get/a?workspace=<WORKSPACE>", "oncall") === "https://x/apps/get/a?workspace=<WORKSPACE>&tab=schedule&mode=shifts&pod=oncall" && R.podUrl("https://x/apps/get/a", "swing") === "https://x/apps/get/a?tab=schedule&mode=shifts&pod=swing");
  check("the fallback constant names the production workspace", /\?workspace=<WORKSPACE>$/.test(R.DASHBOARD_URL));
  const s0 = { id: "u1", kind: "oncall", week_start: "2026-10-12", covers: R.wholeWeek("2026-10-12"), exchange: null, from: party(eng1), to: party(eng2), note: "", status: "pending", requested_at: "2026-09-09T14:00:00.000Z", decided_at: null, decided_by: null };
  check("every card button lands on the pod it is about", /&tab=schedule&mode=shifts&pod=oncall$/.test(R.swapEvent("request", s0, null).url) && /pod=swing$/.test(R.swapEvent("request", { ...s0, kind: "swing", week_start: "2026-09-19", covers: { from: "2026-09-19", to: "2026-09-20" } }, null, "https://d/app?workspace=w").url));
  check("etMidnightMs is memoised and still DST-correct", R.etMidnightMs("2026-07-04") === Date.parse("2026-07-04T04:00:00Z") && R.etMidnightMs("2026-12-05") === Date.parse("2026-12-05T05:00:00Z") && R.etMidnightMs("2026-07-04") === R.etMidnightMs("2026-07-04"));
  const snapFresh = { name: "<ENGINEER_7>", email: "engineer7@example.com", ext: "1007", rc_id: null, agent_id: 14, base_name: "<ENGINEER_7>", swap_id: null, swap_reason: null, source: "record", recorded_at: "2026-09-05T17:05:00.000Z", job_id: "j", reason: null, actions: 90, tickets: 10, first_action: "2026-09-05T12:05:00.000Z", last_action: "2026-09-05T13:00:00.000Z", activity_as_of: "2026-09-05T17:05:00.000Z" };
  const snapFinal = { ...snapFresh, activity_as_of: "2026-09-13T04:10:00.000Z", actions: 155, tickets: 17, last_action: "2026-09-05T15:50:07.000Z" };
  check("activityFinal: a cache taken at freeze is provisional; one taken a week later is final", !R.activityFinal(snapFresh, "2026-09-05") && R.activityFinal(snapFinal, "2026-09-05"));
  const cfg = R.resolveConfig({ swing: { pool: R.MOCK_SWING, anchor: "2026-09-05" } }).cfg; const now = et("2026-09-17T20:00:00Z");
  const live = [{ date: "2026-09-05", agent_id: 14, actions: 155, tickets: 17, first_at: "2026-09-05T12:05:00.000Z", last_at: "2026-09-05T15:50:07.000Z" }];
  const hLive = R.buildHistory(now, cfg.swing, [], null, live, () => 14, 21, { saturdays: { "2026-09-05": snapFresh } });
  const hCache = R.buildHistory(now, cfg.swing, [], null, [], () => 14, 21, { saturdays: { "2026-09-05": snapFinal } });
  const hNone = R.buildHistory(now, cfg.swing, [], null, [], () => 14, 21, { saturdays: { "2026-09-05": { ...snapFresh, actions: null, activity_as_of: null } } });
  const row = (h: any[]) => h.find(x => x.date === "2026-09-05");
  check("history: live numbers win while fresh, the final cache serves when no query ran, and no cache + no query reads as zero actions (worked · no ticks vs no evidence)", row(hLive).actions === 155 && row(hCache).actions === 155 && row(hCache).tickets === 17 && row(hCache).flag === "no_ticks" && row(hNone).actions === 0 && row(hNone).flag === "no_evidence");
  const snap = R.snapshotFor("2026-09-12", cfg.swing, [], null, () => 111, et("2026-09-12T17:30:00Z"), "j", [], [{ date: "2026-09-12", agent_id: 111, actions: 7, tickets: 3, first_at: "2026-09-12T12:10:00.000Z", last_at: "2026-09-12T16:00:00.000Z" }]);
  check("snapshotFor caches the day's activity at freeze (provisional)", snap.actions === 7 && snap.tickets === 3 && !!snap.activity_as_of && !R.activityFinal(snap, "2026-09-12"));
  const cfgS = R.resolveConfig({ swing: { pool: R.MOCK_SWING, anchor: "2026-08-01" } });
  const rcS = { configured: true, ok: true, error: null, checked_at: "2026-09-10T20:31:19Z", members: liveQueue(), account: "<RC_ACCOUNT_ID>", queue: "<RC_QUEUE_ID>" };
  const both = [s0, { ...s0, id: "u2", status: "declined", decided_at: "2026-09-09T15:00:00.000Z", decided_by: party(eng2) }];
  const full = R.assemble(et("2026-09-10T20:31:19Z"), rcS, 4, "details", cfgS, both, null, {});
  const slim = R.assemble(et("2026-09-10T20:31:19Z"), rcS, 4, "all", cfgS, both, null, { slim: true });
  check("slim poll: pending swaps only with a count, no member list but a count, no history rows but a count; details keeps everything", slim.oncall.swaps.length === 1 && slim.oncall.swaps_count === 2 && slim.oncall.ringcentral.members.length === 0 && slim.oncall.ringcentral.count === 6 && slim.swing.history.length === 0 && slim.swing.history_count > 0 && slim.oncall.slim === true && full.oncall.swaps.length === 2 && full.oncall.ringcentral.members.length === 6 && full.swing.history.length > 0 && full.oncall.slim === undefined);
  check("the drift verdict survives the slim payload (computed before members are dropped)", slim.oncall.drift.state === full.oncall.drift.state && slim.oncall.drift.headline === full.oncall.drift.headline);
  check("slim is smaller", JSON.stringify(slim).length < JSON.stringify(full).length, `${JSON.stringify(slim).length} vs ${JSON.stringify(full).length}`);
}

console.log("presence writer (phase 4): the plan, and the writer agrees with the pods on who holds today");
{
  const threw = (f: () => any): string => { try { f(); return ""; } catch (e: any) { return String(e?.message || e); } };
  // The writer is a workspace script with its own copy of the per-day holder logic; load it the same way and cross-check.
  // The presence writer (f/rmm/oncall_presence_writer.ts in the Windmill workspace) is NOT part of this extraction;
  // its pure presence functions are published separately as github.com/AlrightLad/ringcentral-queue-presence.
  const wsrc = readFileSync(resolve(import.meta.dir, "oncall_presence_writer.ts"), "utf8")
    .replace(/^import \* as wmill from "windmill-client";\s*$/m, "const wmill = undefined;").replace(/^import postgres from "postgres";\s*$/m, "const postgres = undefined;")
    .replace(/^export (const|function|type|async function) /gm, "$1 ");
  new Function(new Bun.Transpiler({ loader: "ts" }).transformSync(`${wsrc}\nglobalThis.__wr = { planPresence, restorePlan, holderOn, pickRoster, mondayOf, normSwap, isProtected, normalizeRc, unconfirmed, flagIsOn };`))();
  const Wr: any = (globalThis as any).__wr;
  const party = (p: any) => ({ agent_id: null, name: p.name, email: p.email ?? null, ext: p.ext, rc_id: p.rc_id ?? null });
  const base = (day: string) => R.pickRoster(D.oncall.pool, D.oncall.anchor, R.mondayOf(day));
  const wed = et("2026-09-09T15:00:00Z");
  const fri = { id: "d1", kind: "oncall", week_start: "2026-09-14", covers: { from: "2026-09-18", to: "2026-09-19" }, exchange: null, from: party(eng1), to: party(eng2), note: "", status: "accepted", requested_at: "x", decided_at: "2026-09-09T14:30:00.000Z", decided_by: party(eng2) };
  const ex = { id: "d2", kind: "oncall", week_start: "2026-09-21", covers: R.wholeWeek("2026-09-21"), exchange: { week_start: "2026-09-28", covers: R.wholeWeek("2026-09-28") }, from: party(eng2), to: party(eng3), note: "", status: "accepted", requested_at: "x", decided_at: "2026-09-09T15:00:00.000Z", decided_by: party(eng3) };
  const legacy = { id: "L", kind: "oncall", period: "2026-10-05", exchange: null, from: party(eng5), to: party(eng1), note: "", status: "accepted", requested_at: "x", decided_at: "2026-09-09T15:30:00.000Z", decided_by: party(eng1) };
  const ovr = R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng5.ext, reason: "<ENGINEER_3> out Friday", covers_from: "2026-09-18", covers_to: "2026-09-19" }, party(eng4), R.resolveConfig(null).cfg, [fri], [], et("2026-09-09T16:00:00Z")).override;
  const ovr2 = R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext, reason: "everyone out" }, party(eng4), R.resolveConfig(null).cfg, [fri], [ovr], et("2026-09-09T17:00:00Z")).override;
  const days = ["2026-09-14", "2026-09-17", "2026-09-18", "2026-09-19", "2026-09-22", "2026-09-30", "2026-10-07", "2026-10-12"];
  const scenarios: [string, any[], any[]][] = [["no swaps", [], []], ["a Friday swap", [fri], []], ["an exchange", [ex], []], ["a legacy whole-week row", [legacy], []], ["a Friday swap under a Friday reassignment", [fri], [ovr]], ["a later whole-week reassignment over both", [fri], [ovr, ovr2]], ["all of it", [fri, ex, legacy], [ovr, ovr2]]];
  let agree = 0, total = 0, diff = "";
  for (const [label, sw, ov] of scenarios) for (const day of days) {
    total++; const a = R.holderOn("oncall", day, base(day), sw, wed.ms, undefined, ov).holder, b = Wr.holderOn("oncall", day, Wr.pickRoster(D.oncall.pool, D.oncall.anchor, Wr.mondayOf(day)), sw, ov).holder;
    if (a.ext === b.ext && a.name === b.name) agree++; else diff += ` [${label} ${day}: pods=${a.name} writer=${b.name}]`;
  }
  check(`the writer's holderOn agrees with the pods' on every day of every scenario (${total} checks)`, agree === total, diff);
  const members = [{ id: "<RC_ID_6>", name: "<ENGINEER_6>", ext: "1006", acceptQueueCalls: true, acceptCurrentQueueCalls: false }, { id: "<RC_ID_1>", name: "<ENGINEER_1>", ext: "1001", acceptQueueCalls: true, acceptCurrentQueueCalls: false },
    { id: "<RC_ID_2>", name: "<ENGINEER_2>", ext: "1002", acceptQueueCalls: true, acceptCurrentQueueCalls: false }, { id: "<RC_ID_5>", name: "<ENGINEER_5>", ext: "1005", acceptQueueCalls: true, acceptCurrentQueueCalls: true }, { id: "<RC_ID_4>", name: "<ENGINEER_4>", ext: "1004", acceptQueueCalls: true, acceptCurrentQueueCalls: true }];
  const prot = new Set(["<RC_ID_6>"]), protExt = new Set(["1006"]);
  const plan = Wr.planPresence(members, { name: "<ENGINEER_1>", ext: "1001", rc_id: "<RC_ID_1>" }, prot, protExt);
  check("the plan sends EVERY non-protected member explicitly, holder true and everyone else false, and never <ENGINEER_6>", plan.rows.length === 4 && !plan.rows.some((r: any) => r.id === "<RC_ID_6>") && plan.rows.find((r: any) => r.id === "<RC_ID_1>").after === true && plan.rows.filter((r: any) => r.after === false).length === 3 && plan.holder_in_queue);
  check("changes are only the members whose value differs: <ENGINEER_1> on, <ENGINEER_5> off, <ENGINEER_4> (not in rotation) off", eq(plan.changes.map((r: any) => [r.ext, r.after]), [["1001", true], ["1005", false], ["1004", false]]));
  const same = Wr.planPresence(members, { name: "<ENGINEER_5>", ext: "1005", rc_id: "<RC_ID_5>" }, prot, protExt);
  check("idempotent: when the queue already matches (except a non-rotation member) only that member changes; with <ENGINEER_4> off too nothing changes", eq(same.changes.map((r: any) => r.ext), ["1004"]) && Wr.planPresence(members.map(m => m.ext === "1004" ? { ...m, acceptCurrentQueueCalls: false } : m), { name: "<ENGINEER_5>", ext: "1005", rc_id: "<RC_ID_5>" }, prot, protExt).changes.length === 0);
  check("a holder who is not a queue member yields holder_in_queue=false (nothing is written)", Wr.planPresence(members, { name: "<ENGINEER_3>", ext: "1003", rc_id: "<RC_ID_3>" }, prot, protExt).holder_in_queue === false);
  // A reassignment can hand today's on-call to the CTO row or a drift_exempt person. Both of those are queue
  // MEMBERS the writer refuses to touch, so holder_in_queue is false for a reason that has nothing to do with
  // queue membership, and the two must not report the same thing.
  {
    const protHolder = Wr.planPresence(members, { name: "<ENGINEER_6>", ext: "1006", rc_id: "<RC_ID_6>" }, prot, protExt);
    const absentHolder = Wr.planPresence(members, { name: "<ENGINEER_3>", ext: "1003", rc_id: "<RC_ID_3>" }, prot, protExt);
    check("a PROTECTED holder is told apart from an ABSENT one: both block the write, only the protected one sets holder_protected",
      protHolder.holder_in_queue === false && protHolder.holder_protected === true
      && absentHolder.holder_in_queue === false && absentHolder.holder_protected === false
      && Wr.planPresence(members, { name: "<ENGINEER_1>", ext: "1001", rc_id: "<RC_ID_1>" }, prot, protExt).holder_protected === false);
  }
  // The read-back is the only thing that knows a write did not take; it has to name who disagreed.
  check("unconfirmed names exactly the rows the read-back did not confirm",
    Wr.unconfirmed([{ id: "<RC_ID_1>", ext: "1001", name: "<ENGINEER_1>", before: false, after: true }, { id: "<RC_ID_5>", ext: "1005", name: "<ENGINEER_5>", before: true, after: false }],
      [{ id: "<RC_ID_1>", ext: "1001", name: "<ENGINEER_1>", acceptQueueCalls: true, acceptCurrentQueueCalls: false }, { id: "<RC_ID_5>", ext: "1005", name: "<ENGINEER_5>", acceptQueueCalls: true, acceptCurrentQueueCalls: false }])
      === "<ENGINEER_1> (x1001) wanted true");
  check("drift-exempt members join the protected set by id or extension and never appear in the plan", Wr.planPresence(members, { name: "<ENGINEER_1>", ext: "1001", rc_id: "<RC_ID_1>" }, new Set(["<RC_ID_6>", "<RC_ID_4>"]), protExt).rows.length === 3 && Wr.planPresence(members, { name: "<ENGINEER_1>", ext: "1001", rc_id: "<RC_ID_1>" }, prot, new Set(["1006", "1004"])).rows.length === 3);
  const snap = [{ id: "<RC_ID_6>", ext: "1006", acceptCurrentQueueCalls: true }, { id: "<RC_ID_1>", ext: "1001", acceptCurrentQueueCalls: true }, { id: "<RC_ID_5>", ext: "1005", acceptCurrentQueueCalls: false }, { id: "999", ext: "1", acceptCurrentQueueCalls: true }];
  const rs = Wr.restorePlan(snap, members, prot, protExt);
  check("restore replays the captured values verbatim for members present now, skips <ENGINEER_6> and members no longer in the queue, and recomputes nothing", eq(rs.rows.map((r: any) => [r.ext, r.after]), [["1001", true], ["1005", false]]) && eq(rs.changes.map((r: any) => r.ext), ["1001", "1005"]));
  // The switch moved out of the roster JSON and into Windmill. What must hold now: the roster can no longer
  // carry a switch at all (a second one would lie), and only the exact string "true" arms it.
  check("the roster JSON no longer carries an rc_writer switch", R.resolveConfig(null).cfg.oncall.rc_writer === undefined && R.resolveConfig({ oncall: { rc_writer: { enabled: true } } }).cfg.oncall.rc_writer === undefined);
  check("the Windmill flag arms on the exact string \"true\" and nothing else (writer's own predicate)", eq(["true", " TRUE ", "yes", "1", "on", "", null, undefined].map(v => Wr.flagIsOn(v)), [true, true, false, false, false, false, false, false]));
  // Every reassignment of `extras` must SPREAD the previous one. v1.13.1 shipped with a rebuild that
  // dropped writer_enabled, so the pod reported the writer disabled however the switch was set — and no
  // behavioural test here could catch it, because reaching that line needs a live database. Assert the
  // shape of the source instead: a bare `extras = {` that does not carry ...extras is the bug returning.
  {
    const rotSrc = readFileSync(resolve(import.meta.dir, "rotation.ts"), "utf8");
    const rebuilds = rotSrc.split("\n").filter((l) => /^\s*extras\s*=\s*\{/.test(l) && !l.includes("...extras"));
    check("every reassignment of extras spreads the previous one (writer_enabled cannot be dropped again)", rebuilds.length === 0, rebuilds.join(" | "));
  }
  check("the dashboard judges the flag with the identical predicate", eq(["true", " TRUE ", "yes", "1", "on", "", null, undefined].map(v => R.flagIsOn(v)), ["true", " TRUE ", "yes", "1", "on", "", null, undefined].map(v => Wr.flagIsOn(v))));
}

console.log("manager override (phase 3)");
{
  const threw = (f: () => any): string => { try { f(); return ""; } catch (e: any) { return String(e?.message || e); } };
  const party = (p: any) => ({ agent_id: null, name: p.name, email: p.email ?? null, ext: p.ext, rc_id: p.rc_id ?? null });
  const cfg = R.resolveConfig(null).cfg; const admin = party(eng4);
  const base = (day: string) => R.pickRoster(D.oncall.pool, D.oncall.anchor, R.mondayOf(day));
  const wed = et("2026-09-09T15:00:00Z");
  const fri = { id: "d1", kind: "oncall", week_start: "2026-09-14", covers: { from: "2026-09-18", to: "2026-09-19" }, exchange: null, from: party(eng1), to: party(eng2), note: "",
    status: "accepted", requested_at: "2026-09-09T14:00:00.000Z", decided_at: "2026-09-09T14:30:00.000Z", decided_by: party(eng2) };
  const r = R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext, reason: "<ENGINEER_1> and <ENGINEER_2> both out" }, admin, cfg, [fri], [], wed);
  check("the displaced set is everyone the range takes from (<ENGINEER_1> Mon–Thu and Sat–Sun, <ENGINEER_2> Fri), the row's displaced is the first", eq(r.displaced.map((p: any) => p.ext), [eng1.ext, eng2.ext]) && r.override.displaced.ext === eng1.ext && r.override.displaced_all.length === 2 && r.superseded.length === 0 && r.override.status === "active" && r.override.id.startsWith("ovr-oncall-2026-09-14-"));
  check("holderOn: the reassignment stands over the accepted swap on Friday and over the base elsewhere", R.holderOn("oncall", "2026-09-18", base("2026-09-18"), [fri], wed.ms, undefined, [r.override]).holder.ext === eng3.ext && R.holderOn("oncall", "2026-09-15", base("2026-09-15"), [fri], wed.ms, undefined, [r.override]).override?.id === r.override.id);
  check("weekRuns: one reassigned run for the whole week", eq(R.weekRuns("2026-09-14", base("2026-09-14"), [fri], wed.ms, undefined, [r.override]).map((x: any) => [x.days, x.ext, x.override_id]), [[7, eng3.ext, r.override.id]]));
  const later = R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng5.ext, reason: "<ENGINEER_3> out Friday too", covers_from: "2026-09-18", covers_to: "2026-09-19" }, admin, cfg, [fri], [r.override], et("2026-09-09T16:00:00Z"));
  check("a later reassignment wins where it overlaps; the earlier one still holds the other days; the displaced person is the earlier cover", R.holderOn("oncall", "2026-09-18", base("2026-09-18"), [fri], wed.ms, undefined, [r.override, later.override]).holder.ext === eng5.ext && R.holderOn("oncall", "2026-09-17", base("2026-09-17"), [fri], wed.ms, undefined, [later.override, r.override]).holder.ext === eng3.ext && later.displaced[0].ext === eng3.ext);
  const w = R.buildOncall(wed, D.oncall, 4, [fri], [r.override, later.override]).upcoming.find((x: any) => x.week_start === "2026-09-14");
  check("buildOncall carries the reassignment mark and splits the week into <ENGINEER_3> / <ENGINEER_5> / <ENGINEER_3>", w.override_id === r.override.id && w.override?.by === eng4.name && w.split && eq(w.runs.map((x: any) => x.ext), [eng3.ext, eng5.ext, eng3.ext]));
  const pend = R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-21", counterparty_ext: eng3.ext, covers_from: "2026-09-25", covers_to: "2026-09-26" }, party(eng2), cfg, [], wed);
  const o2 = R.applyOverride({ kind: "oncall", period: "2026-09-21", counterparty_ext: eng5.ext, reason: "<ENGINEER_2> out" }, admin, cfg, pend.swaps, [], wed);
  check("pending requests overlapping the range close as superseded, naming the reassignment", o2.superseded.length === 1 && o2.superseded[0].status === "superseded" && o2.superseded[0].superseded_by === o2.override.id && /superseded by a reassignment: <ENGINEER_2> out/.test(o2.superseded[0].decided_reason ?? "") && o2.swaps.find((x: any) => x.id === pend.swap.id)?.status === "superseded" && eq(o2.override.superseded_swap_ids, [pend.swap.id]));
  check("a superseded request is no longer pending for overlap checks and cannot be accepted", R.pendingOverlapping("oncall", { from: "2026-09-25", to: "2026-09-26" }, o2.swaps, wed.ms) === null && /is superseded, not pending/.test(threw(() => R.applySwapAction("swap_accept", { id: pend.swap.id }, party(eng3), cfg, o2.swaps, wed))));
  check("you cannot give away a day an admin moved off you", /you do not hold Mon 2026-09-21; <ENGINEER_5> does/.test(threw(() => R.applySwapAction("swap_request", { kind: "oncall", period: "2026-09-21", counterparty_ext: eng3.ext }, party(eng2), cfg, o2.swaps, wed, [o2.override]))));
  check("refusals: no reason · range over · cover already covers · Saturday partial · week boundary · no identity", /a reason is required/.test(threw(() => R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext, reason: "  " }, admin, cfg, [], [], wed)))
    && /is over; only today and future days/.test(threw(() => R.applyOverride({ kind: "oncall", period: "2026-08-31", counterparty_ext: eng3.ext, reason: "late" }, admin, cfg, [], [], wed)))
    && /<ENGINEER_1> already covers week of Mon 2026-09-14/.test(threw(() => R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng1.ext, reason: "noop" }, admin, cfg, [], [], wed)))
    && /reassigned whole/.test(threw(() => R.applyOverride({ kind: "swing", period: "2026-09-19", counterparty_ext: R.MOCK_SWING[1].ext, reason: "sick", covers_from: "2026-09-19", covers_to: "2026-09-21" }, admin, cfg, [], [], wed)))
    && /never crosses a week boundary/.test(threw(() => R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext, reason: "x", covers_from: "2026-09-20", covers_to: "2026-09-22" }, admin, cfg, [], [], wed)))
    && /identity could not be established/.test(threw(() => R.applyOverride({ kind: "oncall", period: "2026-09-14", counterparty_ext: eng3.ext, reason: "x" }, null, cfg, [], [], wed))));
  check("today can be reassigned (a Wednesday no-show), yesterday cannot", !threw(() => R.applyOverride({ kind: "oncall", period: "2026-09-07", counterparty_ext: eng1.ext, reason: "<ENGINEER_5> out today", covers_from: "2026-09-09", covers_to: "2026-09-10" }, admin, cfg, [], [], wed)) && /is over/.test(threw(() => R.applyOverride({ kind: "oncall", period: "2026-09-07", counterparty_ext: eng1.ext, reason: "x", covers_from: "2026-09-08", covers_to: "2026-09-09" }, admin, cfg, [], [], wed))));
  const c = R.cancelOverride(o2.override, admin, "<ENGINEER_2> is back", et("2026-09-10T15:00:00Z"));
  check("cancel: status cancelled with who/when/why; twice is refused; without a reason is refused; then coverage returns to the roster", c.status === "cancelled" && c.cancelled_by?.ext === eng4.ext && c.cancelled_reason === "<ENGINEER_2> is back" && /already cancelled/.test(threw(() => R.cancelOverride(c, admin, "again", wed))) && /a reason is required/.test(threw(() => R.cancelOverride(o2.override, admin, "", wed))) && R.holderOn("oncall", "2026-09-22", base("2026-09-22"), o2.swaps, wed.ms, undefined, [c]).holder.ext === eng2.ext && R.activeOverrides([c, r.override]).length === 1);
  const evD = R.overrideEvent("displaced", r.override, r.override.displaced, "displaced"), evC = R.overrideEvent("cover", r.override, r.override.to, "cover"), evX = R.overrideEvent("cancelled", c, c.to, "cover");
  check("the displaced card says reassignment, not a swap you agreed to, to one recipient, with reason and who did it", /On-call REASSIGNMENT · week of Mon 2026-09-14/.test(evD.title) && /manager reassignment, not a swap you agreed to/.test(evD.summary) && evD.recipients.length === 1 && evD.recipients[0].role === "displaced" && evD.event === "override" && evD.override_id === r.override.id && evD.swap_id === null && evD.facts.some((f: any) => f.name === "Reason" && f.value === "<ENGINEER_1> and <ENGINEER_2> both out") && evD.facts.some((f: any) => f.name === "Reassigned by" && /<ENGINEER_4>/.test(f.value)));
  check("the cover card says nobody asked them to accept it; the cancelled card says coverage returns", /not a swap — nobody asked you to accept it/.test(evC.summary) && evC.recipients[0].role === "cover" && /reassignment cancelled/.test(evX.title) && /coverage returns to the roster/.test(evX.summary));
  const evS = R.supersededEvent(o2.superseded[0], o2.override, o2.superseded[0].to, "counterparty");
  check("the superseded card names the reassignment and says nothing is waiting", evS.event === "superseded" && evS.swap_id === pend.swap.id && evS.override_id === o2.override.id && /Nothing is waiting on you/.test(evS.summary) && evS.recipients[0].role === "counterparty");
  const o3 = R.applyOverride({ kind: "swing", period: "2026-09-19", counterparty_ext: R.MOCK_SWING[2].ext, reason: "sick" }, admin, cfg, [], [], wed);
  const snap = R.snapshotFor("2026-09-19", cfg.swing, [], null, () => null, et("2026-09-21T20:00:00Z"), "j", [o3.override]);
  check("a reassigned Saturday is recorded as such, never as a swap", snap.source === "override" && snap.name === R.MOCK_SWING[2].name && snap.override_id === o3.override.id && /reassigned by <ENGINEER_4>: sick/.test(snap.reason ?? "") && snap.swap_id === null);
  const sats = R.buildSwing(wed, cfg.swing, 4, [], [o3.override]).saturdays;
  check("the Saturday row carries the reassignment mark", sats.find((x: any) => x.date === "2026-09-19")?.override_id === o3.override.id && sats.find((x: any) => x.date === "2026-09-19")?.override?.displaced === R.MOCK_SWING[1].name);
  check("overrideView labels the range", R.overrideView(o3.override).label === "Sat 2026-09-19" && R.overrideView(r.override).whole === true && R.overrideView(later.override).whole === false);
}

console.log("admin gate (Plan 3)");
{
  const threw = (f: () => any): string => { try { f(); return ""; } catch (e: any) { return String(e?.message || e); } };
  const admins = [{ email: "engineer6@example.com", name: "<ENGINEER_6>" }, { email: "engineer4@example.com", name: "<ENGINEER_4>" }];
  check("isAdmin: case-insensitive email match; null email and an empty list are never admin", R.isAdmin("Engineer6@example.com", admins) && !R.isAdmin("engineer5@example.com", admins) && !R.isAdmin(null, admins) && !R.isAdmin("engineer6@example.com", []));
  const f = R.adminFields("engineer5@example.com", { admins, note: null });
  check("adminFields: not admin, and the list rides along for the UI", f.is_admin === false && f.admins.length === 2 && f.admin_note === null);
  check("adminGate names the group, its members and the caller", /limited to rotation admins — the Windmill group rotation_admins \(<ENGINEER_6>, <ENGINEER_4>\).*engineer5@example\.com is not a member\./.test(threw(() => R.adminGate({ email: "engineer5@example.com", ...f }, "Changing the rotation roster"))));
  const empty = { admins: [], note: `Admin group ${R.ADMIN_GROUP} has no members — admin actions are off.` };
  check("empty or unreadable group: nobody is admin, the reason is carried", !R.adminFields("engineer6@example.com", empty).is_admin && /nobody yet.*has no members/.test(threw(() => R.adminGate({ email: "engineer6@example.com", ...R.adminFields("engineer6@example.com", empty) }, "Resetting the rotation roster"))));
  check("no end-user email is never admin", !R.adminFields(null, { admins, note: null }).is_admin && /carries no end-user email/.test(threw(() => R.adminGate({ email: null, ...R.adminFields(null, { admins, note: null }) }, "x"))));
  check("a member passes the gate silently", !threw(() => R.adminGate({ email: "ENGINEER4@example.com", ...R.adminFields("ENGINEER4@example.com", { admins, note: null }) }, "x")));
}

console.log("assembly");
{
  const resolved = R.resolveConfig(null);
  const rc = { configured: true, ok: true, error: null, checked_at: "2026-09-10T20:31:19Z", members: liveQueue(), account: "<RC_ACCOUNT_ID>", queue: "<RC_QUEUE_ID>" };
  const out = R.assemble(et("2026-09-10T20:31:19Z"), rc, 4, "all", resolved);
  check("live shape → green, CTO row present with queue state, sources reported", out.oncall.drift.state === "ok" && out.oncall.cto.ext === "1006" && out.oncall.cto_in_queue?.acceptCurrentQueueCalls === false && out.oncall.roster_source === "default" && out.swing.roster_source === "mock" && out.config.key === "ops_rotation");
  check("past Saturdays under the defaults (effective_from Sep 12): every passed Saturday predates this roster → none listed, 13 counted with their range", out.swing.history.length === 0 && out.swing.history_omitted.count === 13 && out.swing.history_omitted.first === "2026-06-13" && out.swing.history_omitted.last === "2026-09-05");
  check("every live member is tagged for the table: <ENGINEER_6> cto, the five pool", out.oncall.ringcentral.members.length === 6 && out.oncall.ringcentral.members.every((m: any) => m.rotation === (m.ext === "1006" ? "cto" : "pool")));
  // The document in effect since 2026-09-10: four in the pool. <ENGINEER_4> is still a member of the queue.
  const four = R.resolveConfig({
    oncall: { pool: [eng1, eng2, eng3, eng5].map((p: any) => ({ name: p.name, ext: p.ext })), anchor: "2026-08-17" },
    swing: { pool: [{ name: "<ENGINEER_7>", ext: "1007" }, { name: "<ENGINEER_8>", ext: "1008" }, { name: "<ENGINEER_9>", ext: "1009" }], anchor: "2026-09-05", approver: { name: "<ENGINEER_4>", ext: "1004" } },
  });
  const o4 = R.assemble(et("2026-09-10T20:31:19Z"), rc, 4, "all", four);
  const eng4Row = o4.oncall.ringcentral.members.find((m: any) => m.ext === "1004");
  check("<ENGINEER_4> in the queue but out of the pool → not in rotation; nobody else is; still green", eng4Row?.rotation === "none" && o4.oncall.ringcentral.members.filter((m: any) => m.rotation === "none").length === 1 && o4.oncall.drift.state === "ok");
  check("leftovers are listed, never dropped", o4.oncall.ringcentral.members.length === 6);
  const eng4On = R.assemble(et("2026-09-10T20:31:19Z"), { ...rc, members: liveQueue({ "1004": [true, true] }) }, 4, "all", four);
  check("a leftover who is enabled is still drift (not exempt)", eng4On.oncall.drift.state === "warn" && eng4On.oncall.drift.findings.some((f: any) => /<ENGINEER_4> \(x1004\)/.test(f.text)));
  check("membershipOf: cto / pool / exempt / none", R.membershipOf(rec(eng6, false), four.cfg.oncall) === "cto" && R.membershipOf(rec(eng1, false), four.cfg.oncall) === "pool"
    && R.membershipOf(rec(eng4, false), { ...four.cfg.oncall, drift_exempt: [{ name: eng4.name, ext: eng4.ext }] }) === "exempt" && R.membershipOf(rec(eng4, false), four.cfg.oncall) === "none");
  const unk = R.assemble(et("2026-09-10T20:31:19Z"), { configured: false, ok: false, error: "missing", checked_at: null, members: [], account: null, queue: null }, 4, "all", resolved);
  check("unreadable RingCentral → unknown, never green", unk.oncall.drift.state === "unknown" && unk.oncall.drift.headline === "RingCentral not configured");
  let threw = false; try { R.assemble(et("2026-09-10T20:31:19Z"), null, 4, "nope", resolved); } catch (_) { threw = true; }
  check("unknown action throws", threw);
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
