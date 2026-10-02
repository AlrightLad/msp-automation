import * as wmill from "windmill-client";
import postgres from "postgres";

// Coverage rota for the Schedule tab: Tier 3 (T3) engineers on-call by week, the CTO standing
// escalation, the Saturday swing shift, a LIVE drift check of the on-call against RingCentral, and
// the SWAP OVERRIDE LAYER on top of both rotations. Feeds the two pods beside the
// Shift Schedule (author, 2026-09-09/10).
//
// ROSTER LIVES IN CONFIG, NOT CODE. automation_config key 'ops_rotation' holds the on-call pool, its
// anchor, the CTO row and the Saturday pool and approver — the same mechanism the dashboard already
// uses for ops_schedule / ops_absence / ops_dashboard. Adding or removing someone from a rotation is
// a config edit, never a code change. DEFAULTS below seed the shape and are used whenever the row is
// absent or a section fails validation; the response says which source each section came from
// (roster_source 'config' | 'default' | 'mock') and lists any validation problems, so a bad edit
// degrades to the defaults visibly rather than blanking the pod. Edit it under Settings → Rotation
// roster (actions config / set / reset below); docs/ops_rotation_config.md is the walkthrough.
//
//   ops_rotation = {
//     oncall: { pool: [{ name, ext, rc_id?, email? }, ...], anchor: "YYYY-MM-DD" (a Monday; pool[0] holds
//               that week, the pool cycles from there), cto: { label, name, ext, rc_id?, guidance },
//               drift_exempt: [{ name, ext, rc_id? }, ...] (in addition to the CTO) },
//     swing:  { pool: [...], anchor: "YYYY-MM-DD" (a Saturday), approver: { name, ext, rc_id?, email? } | null }
//   }
//
// SWAPS ARE AN OVERRIDE LAYER, NOT A ROSTER EDIT. A swap never touches oncall.pool, swing.pool or an
// anchor; the base cycle stays intact and a swap is a dated exception stored separately in
// automation_config key 'ops_rotation_swaps' ({ swaps: [...] }, same upsert + audit pattern). The
// effective holder of a period is the base pick with accepted swaps applied in decision order, so
// two people swapping one week never reorder the cycle. Models (author, 2026-09-10):
//   on-call  — MUTUAL CONSENT: the effective holder of a week proposes a counterparty from the pool
//              (optionally offering one of the counterparty's weeks in exchange); the counterparty
//              accepts or declines; effective only when both have approved; no team lead.
//   Saturday — SINGLE APPROVER: the effective holder proposes; swing.approver (<ENGINEER_4> x1004
//              in config) approves or declines.
// Identity for every swap action comes from the job — WM_END_USER_EMAIL, the app viewer's Windmill
// login, verified populated on an app-triggered run in <DEV_WORKSPACE> 2026-09-10 — mapped to a PSA agent
// through psa_agent.email and matched to a pool row by email or name. No action accepts an actor
// from the client, and authorisation is enforced here, not by hiding buttons: only the counterparty
// (on-call) or the approver (Saturday) can accept or decline, only the requester can cancel, and a
// run with no end-user email cannot write at all. A pending request expires when its period starts.
//
// THE DRIFT CHECK IS LIVE and compares RingCentral against the EFFECTIVE on-call, so an accepted swap
// is exactly what the Monday cutover is then expected to match. The emergency line forwards to
// whoever RingCentral has enabled on the Tier 3 On Call queue. The backend reads GET /restapi/v1.0/account/{account}/call-queues/{queue}/presence: each
// record carries acceptCurrentQueueCalls (enabled for THIS queue — what the cutover toggles) and
// acceptQueueCalls (the extension accepts queue calls AT ALL). Exactly one rotation member should be
// enabled, and it must be the effective on-call. A member enabled for the queue whose extension
// refuses queue calls is marked on-call and receives nothing — a silent coverage failure — and is the
// case this check exists to catch. Verified live 2026-09-10: six members, fields exactly
// records[].member.{id,name,extensionNumber} + the two booleans.
//
// NAMED EXCEPTION — THE CTO. <ENGINEER_6> (RingCentral id <RC_ID_6>, x1006) remains a member of the
// queue as standing escalation. Whether he is enabled says nothing about whether the rotation was
// cut over, so he is removed from the set the "exactly one enabled" invariant is evaluated over: never
// the extra enabled member, never flagged when disabled, never the reason for "nobody". His state is
// still returned so the member table can show it, tagged exempt. The exemption is data (cto +
// drift_exempt in config), so it follows whoever holds the role.
//
// SEVERITY. ok = roster and RingCentral agree. warn = they name different people (last week's on-call
// still enabled before the 9:00 AM Monday cutover reads softly as "cutover pending"), or more than one
// rotation member enabled. bad = no rotation member effectively takes calls: none enabled, or the
// enabled on-call's extension refuses queue calls. unknown = RingCentral could not be read — reported
// as such, never as green.
//
// CREDENTIALS follow the workspace pattern: a `ringcentral` resource type and an f/rmm/ringcentral
// resource whose secret fields are $var: references to Windmill secret variables (values live in the team
// password manager). JWT grant preferred; legacy password grant only
// when the jwt field is empty. The JWT's scope includes EditPresence; this code only reads. Nothing
// here writes to RingCentral.
//
// TIME. Everything is Eastern, like the rest of the dashboard. Dates are YYYY-MM-DD strings handled
// with UTC arithmetic (the todayEt() pattern) so the worker's zone never leaks in.
//
// ONE CALL SERVES BOTH PODS (action 'all'); the RingCentral round-trip is the slow part and a second
// job per refresh would double the queue load for a table that is arithmetic. Every call mints a
// RingCentral token, so the UI polls this at 2× POLL_MS.

export const TZ = "America/New_York";
export const KB_LINK = "https://<KB_HOST>/link";
export const CONFIG_KEY = "ops_rotation";
export const SWAPS_KEY = "ops_rotation_swaps";

export type Person = { name: string; ext: string; rc_id?: string | null; email?: string | null };
export type Cto = Person & { label: string; guidance: string };
export type RotationConfig = {
  oncall: { pool: Person[]; anchor: string; cto: Cto; drift_exempt: Person[] };   // the presence writer's on/off switch is NOT here — see WRITER_FLAG_VAR
  swing: { pool: Person[]; anchor: string; effective_from: string; approver: Person | null };   // effective_from: the first Saturday this roster applied to (history judges from here); defaults to the anchor
};

// >>> Saturday placeholders — not staff. Replaced by a config row naming real people. <<<
export const MOCK_SWING: Person[] = [
  { name: "Taylor Brooks", ext: "111" },
  { name: "Morgan Lee", ext: "112" },
  { name: "Dana Whitfield", ext: "113" },
  { name: "Riley Chen", ext: "114" },
  { name: "Casey Nguyen", ext: "115" },
];

export const DEFAULTS: RotationConfig = {
  oncall: {
    // UNVERIFIED ORDER AND ANCHOR — provenance, so nobody mistakes this for a schedule:
    //   * The five names are right (author, 2026-09-10) but their ORDER here is simply the order they
    //     were listed, which is also the order RingCentral returned the queue members in. Nobody has
    //     said the cycle runs in this sequence.
    //   * The ANCHOR was reverse-engineered from a single observation: on 2026-09-10 RingCentral had
    //     <ENGINEER_5> enabled, so the anchor was set to make the week of 2026-09-07 resolve to him.
    // That is circular. The drift check exists to compare an independent roster against RingCentral;
    // a roster derived FROM RingCentral's current state agrees with it by construction, so a green
    // result on these defaults proves nothing about whether the right person is on-call. The pod
    // therefore badges the on-call roster UNVERIFIED and de-emphasises the Upcoming list until a
    // config row (oncall_source 'config') is saved from the real schedule — the Shifts app in
    // Microsoft Teams per the on-call SOP. Do not "fix" the order or anchor in code; that is the same
    // guess again. (<DEV_WORKSPACE> has had a real config row since 2026-09-10; these defaults are the
    // fallback only.)
    pool: [
      { name: "<ENGINEER_1>", ext: "1001", rc_id: "<RC_ID_1>" },
      { name: "<ENGINEER_2>", ext: "1002", rc_id: "<RC_ID_2>" },
      { name: "<ENGINEER_3>", ext: "1003", rc_id: "<RC_ID_3>" },
      { name: "<ENGINEER_4>", ext: "1004", rc_id: "<RC_ID_4>" },
      { name: "<ENGINEER_5>", ext: "1005", rc_id: "<RC_ID_5>" },
    ],
    anchor: "2026-08-10",   // a Monday: pool[0] held that week, so 2026-09-07 is pool[4]
    cto: { label: "CTO", name: "<ENGINEER_6>", ext: "1006", rc_id: "<RC_ID_6>",
      guidance: "CTO escalation — Tier 3 only, or if the on-call Tier 3 engineer does not respond." },
    drift_exempt: [],
  },
  swing: {
    pool: MOCK_SWING,
    anchor: "2026-09-12",   // a Saturday: pool[0] covers it
    effective_from: "2026-09-12",
    approver: { name: "<ENGINEER_4>", ext: "1004", rc_id: "<RC_ID_4>" },
  },
};

export const ONCALL = {
  emergency_line: "",
  queue_extension: "",
  cutover_hm: "09:00",           // On-call SOP: cutover complete by 9:00 AM every Monday, then the test call
  rotation_label: "Monday 12:00 AM – Sunday 11:59 PM ET",
  sop_page: 0,
  sop_title: "Tier 3 On-Call Rotation",
  approval: {
    model: "mutual" as const,
    text: "Swaps are by mutual consent of the two technicians swapping: the requester proposes, the counterparty accepts, and the swap takes effect only when both have approved. Neither can act alone; no team lead is involved.",
  },
};

export const SWING = {
  start_hm: "08:00",
  end_hm: "13:00",
  hours_label: "8:00 AM – 1:00 PM ET",
  sop_page: 0,
  sop_title: "T1 Daily Shift-Start Routine & NOC Checklist",
  // The tickable five from the KB page, corrected 2026-09-11 by the tech who runs it; `where` and
  // `flag` are the page's own "Where" and "Red Flag" columns so a tech ticking the box knows what would
  // make it not a tick. The handoff is NOT a tick: it applies rarely, so it is a standing note under
  // the list and never counts toward completion (the score is out of 5).
  // Guidance, not a task: rendered under the five as a standing note, never ticked, never counted.
  // Wording from the tech who runs the shift (2026-09-11). <ENGINEER_6> x1006 is written out here on
  // purpose — the note is the SOP text, not a lookup of the CTO row.
  checklist_note: { label: "Escalation and handoff",
    body: "The on-call Tier 3 engineer is kept informed of anything active and provides direction to the Saturday technician, or hands-on assistance where the work requires it. If the on-call Tier 3 engineer cannot be reached, escalate to <ENGINEER_6> (x1006) and post in the TECHS chat in Teams for visibility.",
    flag: "anything verbal goes in PSA", when: "guidance · not a tick · not counted" },
  checklist: [
    { n: 1, label: "Open P1s / active incidents", where: "PSA → All Open → Priority Critical", flag: "any P1 with no update in 2+ hours" },
    { n: 2, label: "Overnight PSA queue", where: "PSA → All Open → sort oldest first", flag: "SLA at risk / SLA breached" },
    { n: 3, label: "NinjaOne alerts", where: "PSA → Alerts on T1 Ingress · PSA NOC board", flag: "server offline, disk critical" },
    { n: 4, label: "Veeam backup failures", where: "PSA NOC board", flag: "any failed backup 48h+" },
    { n: 5, label: "Work scheduled for this Saturday", where: "PSA Calendar / Scheduled Work — review the schedule for anything booked today (rare, but it happens)", flag: "active migrations today" },
  ],
};

// ---- config ---------------------------------------------------------------------------------------
export type ResolvedConfig = { cfg: RotationConfig; oncall_source: "config" | "default"; swing_source: "config" | "mock"; problems: string[] };

const ISO = /^\d{4}-\d{2}-\d{2}$/;
const str = (v: any) => (typeof v === "string" ? v.trim() : typeof v === "number" ? String(v) : "");
// A roster row needs BOTH a name and an extension: the drift check matches RingCentral members on
// extension (and rc_id when present), so a name-only row could never be confirmed as on-call. An
// optional email lets the swap flows match the viewer exactly instead of by name.
const person = (v: any): Person | null => {
  const name = str(v?.name), ext = str(v?.ext ?? v?.extension ?? v?.extensionNumber);
  if (!name || !ext) return null;
  return { name, ext, rc_id: str(v?.rc_id ?? v?.id) || null, email: str(v?.email).toLowerCase() || null };
};
const pool = (v: any): Person[] | null => {
  if (!Array.isArray(v) || !v.length) return null;
  const ps = v.map(person).filter((p): p is Person => !!p);
  return ps.length === v.length ? ps : null;
};

// Validate per section and fall back per section, saying why, so a typo in the Saturday list cannot
// take the on-call pool down with it and a bad edit never silently becomes the defaults. The same
// function gates `set`: a document with any problem is refused rather than saved-and-ignored.
export function resolveConfig(raw: any): ResolvedConfig {
  const problems: string[] = [];
  const cfg: RotationConfig = { oncall: { ...DEFAULTS.oncall, pool: [...DEFAULTS.oncall.pool], drift_exempt: [...DEFAULTS.oncall.drift_exempt] },
                                swing: { ...DEFAULTS.swing, pool: [...DEFAULTS.swing.pool] } };
  let oncall_source: ResolvedConfig["oncall_source"] = "default";
  let swing_source: ResolvedConfig["swing_source"] = "mock";
  const v = typeof raw === "string" ? (() => { try { return JSON.parse(raw); } catch (_) { return null; } })() : raw;
  if (v == null) return { cfg, oncall_source, swing_source, problems };
  if (typeof v !== "object") { problems.push(`${CONFIG_KEY} is not an object; using defaults`); return { cfg, oncall_source, swing_source, problems }; }

  // A section may carry only the fields being changed (just the approver, just the CTO row); the
  // pool and anchor are validated as a pair only when either is present.
  if (v.oncall != null) {
    if ("pool" in v.oncall || "anchor" in v.oncall) {
      const p = pool(v.oncall.pool);
      const anchor = str(v.oncall.anchor);
      if (!p) problems.push("oncall.pool must be a non-empty array of { name, ext } — both required on every row; using the default pool");
      else if (!ISO.test(anchor)) problems.push("oncall.anchor must be YYYY-MM-DD; using the default pool and anchor");
      else if (isoDow(anchor) !== 1) problems.push(`oncall.anchor ${anchor} is not a Monday; using the default pool and anchor`);
      else { cfg.oncall.pool = p; cfg.oncall.anchor = anchor; oncall_source = "config"; }
    }
    if (v.oncall.cto != null) {
      const c = person(v.oncall.cto);
      if (!c) problems.push("oncall.cto must have name and ext; keeping the default CTO row");
      else cfg.oncall.cto = { ...c, label: str(v.oncall.cto.label) || DEFAULTS.oncall.cto.label, guidance: str(v.oncall.cto.guidance) || DEFAULTS.oncall.cto.guidance };
    }
    if (v.oncall.drift_exempt != null) {
      const ex = Array.isArray(v.oncall.drift_exempt) ? v.oncall.drift_exempt.map(person).filter((p: Person | null): p is Person => !!p) : null;
      if (ex == null) problems.push("oncall.drift_exempt must be an array; ignoring it");
      else cfg.oncall.drift_exempt = ex;
    }
    // The writer flag is read strictly: only boolean true enables it; anything else is off.
  }
  if (v.swing != null) {
    if ("pool" in v.swing || "anchor" in v.swing) {
      const p = pool(v.swing.pool);
      const anchor = str(v.swing.anchor);
      if (!p) problems.push("swing.pool must be a non-empty array of { name, ext } — both required on every row; using the placeholder pool");
      else if (!ISO.test(anchor)) problems.push("swing.anchor must be YYYY-MM-DD; using the placeholder pool and anchor");
      else if (isoDow(anchor) !== 6) problems.push(`swing.anchor ${anchor} is not a Saturday; using the placeholder pool and anchor`);
      else { cfg.swing.pool = p; cfg.swing.anchor = anchor; swing_source = "config"; }
    }
    // "Before the anchor" stood in for "before this roster applied", which a future anchor breaks; the
    // roster says explicitly from which Saturday it applies. Absent → the anchor, as before.
    const ef = str(v.swing.effective_from);
    if (v.swing.effective_from != null && !ISO.test(ef)) problems.push("swing.effective_from must be YYYY-MM-DD; using the anchor");
    cfg.swing.effective_from = v.swing.effective_from != null && ISO.test(ef) ? ef : cfg.swing.anchor;
    if ("approver" in v.swing) {
      if (v.swing.approver == null) cfg.swing.approver = null;
      else { const a = person(v.swing.approver); if (!a) problems.push("swing.approver must have name and ext; keeping the default approver"); else cfg.swing.approver = a; }
    }
  }
  return { cfg, oncall_source, swing_source, problems };
}

function pg(db: any) {
  return postgres({ host: db.host, port: db.port, user: db.user, password: db.password,
    database: db.dbname, ssl: db.sslmode === "require" ? "require" : false,
    connect_timeout: 15, idle_timeout: 30, max_lifetime: 60 * 30, keep_alive: 30,
    connection: { statement_timeout: "20000", jit: "off" },
  });
}

const parseJson = (raw: any) => typeof raw === "string" ? (() => { try { return JSON.parse(raw); } catch (_) { return raw; } })() : raw;
async function readKey(sql: any, key: string): Promise<any> {
  const rows = await sql`select value from automation_config where key = ${key}`;
  return parseJson(rows[0]?.value ?? null);
}
// Upsert, not update: the row does not exist until first saved and an UPDATE against a missing key
// silently succeeds with zero rows. The audit row is a log and never the reason a save fails.
async function upsertKey(sql: any, key: string, value: any, action: string, actor: string, detail: any) {
  await sql`insert into automation_config (key, value, updated_at) values (${key}, ${sql.json(value)}, now())
            on conflict (key) do update set value = excluded.value, updated_at = now()`;
  try { await sql`insert into automation_audit (actor, action, device_id, detail) values (${actor}, ${action}, null, ${sql.json(detail)})`; } catch (_) {}
}

// WHO CHANGED IT is read from the job, never from the caller. The rest of this app sends
// `actor: 'console'` from the browser, which is a client-chosen string; a rotation edit changes who
// the desk is told to call, so its audit row must not be spoofable. Windmill sets WM_END_USER_EMAIL to
// the app viewer's login email on runs triggered from an app (empty on any other kind of run), so that
// is the actor; when it is empty the row says "unattributed" rather than borrowing the publisher's
// identity from WM_EMAIL. The job's own identity is kept in the detail for forensics.
export const UNATTRIBUTED = "unattributed";
export function jobActor(env: Record<string, string | undefined> = process.env) {
  const end_user_email = String(env.WM_END_USER_EMAIL ?? "").trim().toLowerCase() || null;
  return { actor: end_user_email ?? UNATTRIBUTED, end_user_email,
    permissioned_as: env.WM_PERMISSIONED_AS ?? null, job_email: env.WM_EMAIL ?? null, job_id: env.WM_JOB_ID ?? null };
}

async function writeConfig(sql: any, st: Storage, action: "set" | "reset", config: any, now: EtNow) {
  const who = jobActor();
  if (action === "set") {
    if (config == null || typeof config !== "object" || Array.isArray(config)) throw new Error("config must be a JSON object with oncall and/or swing sections");
    const r = resolveConfig(config);
    if (r.problems.length) throw new Error("Not saved — fix these first: " + r.problems.join(" "));
    // Moment (2) of the coverage snapshot: before the roster changes, freeze every passed Saturday
    // that has no record yet under the roster being replaced. Best effort — never blocks the save.
    try {
      const prev = resolveConfig(await readKey(sql, CONFIG_KEY));
      const [swaps, chk, coverage, ovrC] = await Promise.all([readSwaps(sql, st, now), readChk(sql, st, now), readCoverage(sql, st, now), readOverrides(sql, st, now)]);
      const emails = [...prev.cfg.swing.pool, ...swaps.filter(x => x.kind === "swing").flatMap(x => [x.from, x.to])].map(p => p.email ?? "").filter(Boolean) as string[];
      const byEmail = await readAgentsByEmail(sql, emails);
      const agentOf = (p: Person) => (p.email ? byEmail.get(p.email.toLowerCase()) ?? null : null);
      const fz = freezeCoverage(coverage, prev.cfg.swing, swaps, now, chk, agentOf, who.job_id, HISTORY_DAYS, ovrC);
      if (fz.frozen.length) await saveCoverage(sql, st, fz.store, fz.frozen, "swing_coverage_snapshot", who.actor, { ...who, dates: fz.frozen, why: "set" });
    } catch (_) {}
    // What is stored is the VALIDATED, normalised document, so the row on disk is exactly what the pod uses.
    await upsertKey(sql, CONFIG_KEY, r.cfg, "rotation_set", who.actor, { ...who, config: r.cfg });
  } else {
    await sql`delete from automation_config where key = ${CONFIG_KEY}`;
    try { await sql`insert into automation_audit (actor, action, device_id, detail) values (${who.actor}, ${"rotation_reset"}, null, ${sql.json({ ...who, reset: true })})`; } catch (_) {}
  }
  const raw = await readKey(sql, CONFIG_KEY);
  return { key: CONFIG_KEY, [action === "set" ? "saved" : "reset"]: true, actor: who.actor, raw, ...resolveConfig(raw), defaults: DEFAULTS };
}

// ---- calendar arithmetic on YYYY-MM-DD strings ---------------------------------------------------
export type EtNow = { ymd: string; dow: number; minutes: number; iso: string; ms: number };   // dow = isodow 1..7 (Mon..Sun)

export const toMin = (hm: string) => { const [h, m] = hm.split(":").map(Number); return h * 60 + m; };
export const addDays = (ymd: string, n: number) => { const d = new Date(`${ymd}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
export const isoDow = (ymd: string) => ((new Date(`${ymd}T00:00:00Z`).getUTCDay() + 6) % 7) + 1;
export const daysBetween = (a: string, b: string) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000);
export const mondayOf = (ymd: string) => addDays(ymd, -(isoDow(ymd) - 1));
export const saturdayOnOrAfter = (ymd: string) => addDays(ymd, (6 - isoDow(ymd) + 7) % 7);
const mod = (n: number, m: number) => ((n % m) + m) % m;

// The current instant as an ET calendar date, weekday and minute-of-day. Intl rather than getHours()
// so the worker's own zone never leaks in.
export function etNow(ms: number = Date.now()): EtNow {
  const d = new Date(ms);
  const p = new Intl.DateTimeFormat("en-US", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(d);
  const g = (t: string) => p.find(x => x.type === t)?.value ?? "";
  const ymd = `${g("year")}-${g("month")}-${g("day")}`;
  const minutes = (Number(g("hour")) % 24) * 60 + Number(g("minute"));   // some engines print "24" at midnight
  return { ymd, dow: isoDow(ymd), minutes, iso: d.toISOString(), ms };
}
// The UTC instant of ET midnight on a calendar day, DST-correct: try the two possible offsets and keep
// the one Intl agrees is 00:00 on that date.
const ET_MIDNIGHT = new Map<string, number>();
export function etMidnightMs(ymd: string): number {
  const hit = ET_MIDNIGHT.get(ymd); if (hit != null) return hit;
  const utc = Date.parse(`${ymd}T00:00:00Z`);
  for (const h of [4, 5]) { const ms = utc + h * 3600000; const e = etNow(ms); if (e.ymd === ymd && e.minutes === 0) { ET_MIDNIGHT.set(ymd, ms); return ms; } }
  const fb = utc + 4 * 3600000; ET_MIDNIGHT.set(ymd, fb); return fb;
}

// Deterministic weekly cycle: how many whole weeks `ymd` is from the anchor picks the person.
export function pickRoster(pool: Person[], anchor: string, ymd: string): Person {
  return pool[mod(Math.floor(daysBetween(anchor, ymd) / 7), pool.length)];
}

// ---- swaps: the override layer -----------------------------------------------------------------------
export type Kind = "oncall" | "swing";
export type Party = { agent_id: number | null; name: string; email: string | null; ext: string | null; rc_id?: string | null };
export type SwapStatus = "pending" | "accepted" | "declined" | "cancelled" | "superseded" | "expired";
// DAY RANGES. What a swap moves is a half-open range of ET calendar days [from, to): a whole on-call
// week is [Mon, next Mon), a Friday is [Fri, Sat), a Saturday shift is [Sat, Sun). A range never crosses
// a week boundary — week_start is the Monday (on-call) or the Saturday itself (swing) it sits in.
export type DayRange = { from: string; to: string };
export type Swap = {
  id: string; kind: Kind;
  week_start: string;
  covers: DayRange;                                              // moves from → to
  exchange: { week_start: string; covers: DayRange } | null;     // on-call only: moves to → from
  from: Party; to: Party;                                        // requester → counterparty who covers
  note: string;
  status: Exclude<SwapStatus, "expired">;   // stored; "expired" is derived from the clock
  requested_at: string; decided_at: string | null; decided_by: Party | null;
  decided_reason?: string | null;           // required for Saturday approve/decline, optional for on-call
  notify?: { request?: NotifyResult | null; decision?: NotifyResult | null; cancel?: NotifyResult | null; superseded?: NotifyResult[] | null };   // Teams, best effort
  superseded_by?: string | null;            // the override that closed a pending request (phase 3)
};

const norm = (s: string) => String(s ?? "").toLowerCase().replace(/\s+/g, " ").trim();
// Same person? Email is exact when both sides have one; extension next (the pool always carries it);
// name last (a PSA agent resolved from WM_END_USER_EMAIL has a name but no extension).
export const samePerson = (a: Partial<Party & Person> | null | undefined, b: Partial<Party & Person> | null | undefined): boolean => {
  if (!a || !b) return false;
  if (a.email && b.email) return a.email.toLowerCase() === b.email.toLowerCase();
  if (a.ext && b.ext) return a.ext === b.ext;
  return !!a.name && !!b.name && norm(a.name) === norm(b.name);
};
export const partyOf = (p: Person, id: Party | null = null): Party =>
  ({ agent_id: id?.agent_id ?? null, name: p.name, email: p.email ?? id?.email ?? null, ext: p.ext, rc_id: p.rc_id ?? null });
const personOf = (p: Party): Person => ({ name: p.name, ext: p.ext ?? "", rc_id: p.rc_id ?? null, email: p.email ?? null });

// When a pending request stops being actionable: the moment the period begins.
export const inRange = (r: DayRange, day: string) => day >= r.from && day < r.to;
export const rangesOverlap = (a: DayRange, b: DayRange) => a.from < b.to && b.from < a.to;
export const rangeDays = (r: DayRange): string[] => { const out: string[] = []; for (let d = r.from; d < r.to && out.length < 8; d = addDays(d, 1)) out.push(d); return out; };
export const wholeWeek = (monday: string): DayRange => ({ from: monday, to: addDays(monday, 7) });
export const wholePeriod = (kind: Kind, period: string): DayRange => kind === "oncall" ? wholeWeek(period) : { from: period, to: addDays(period, 1) };
export const isWholePeriod = (kind: Kind, week_start: string, r: DayRange) => r.from === week_start && r.to === addDays(week_start, kind === "oncall" ? 7 : 1);
const DOW_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
export const dowShort = (ymd: string) => DOW_SHORT[isoDow(ymd) % 7];
// "week of Mon 2026-09-14" · "Fri 2026-09-18" · "Wed 2026-09-16 – Fri 2026-09-18" · "Sat 2026-09-12"
export function rangeLabel(kind: Kind, week_start: string, r: DayRange): string {
  if (kind === "swing") return `Sat ${r.from}`;
  if (isWholePeriod(kind, week_start, r)) return `week of Mon ${week_start}`;
  const last = addDays(r.to, -1);
  return r.from === last ? `${dowShort(r.from)} ${r.from}` : `${dowShort(r.from)} ${r.from} – ${dowShort(last)} ${last}`;
}
// Rows written before day ranges existed carry `period` (and `exchange` as a string): read as whole periods.
export function normSwap(s: any): Swap {
  if (s && s.covers && s.week_start && (s.period == null || s.period === s.week_start)) {
    const ex = s.exchange;
    return { ...s, exchange: ex ? (typeof ex === "string" ? { week_start: ex, covers: wholeWeek(ex) } : ex) : null };
  }
  const kind: Kind = s?.kind === "swing" ? "swing" : "oncall";
  const period = String(s?.period ?? s?.week_start ?? "");
  const { period: _p, ...rest } = s ?? {};
  return { ...rest, kind, week_start: period, covers: wholePeriod(kind, period),
    exchange: kind === "oncall" && s?.exchange ? (typeof s.exchange === "string" ? { week_start: s.exchange, covers: wholeWeek(s.exchange) } : s.exchange) : null } as Swap;
}
export const periodStartMs = (kind: Kind, period: string) => etMidnightMs(period) + (kind === "swing" ? toMin(SWING.start_hm) * 60000 : 0);
// A period can be swapped until the END of its first covered day: the next ET midnight for on-call, the end
// of the shift (SWING.end_hm) for a Saturday. A request may be made and accepted while that day is still
// running; a day that has fully ended is history. A multi-day range therefore expires with its first day,
// not its last. (Until 2026-09-12 the boundary was the START of the day, which made a same-day swap — and
// the presence writer's swap-accept trigger — unreachable.)
export const periodEndMs = (kind: Kind, period: string) => kind === "swing" ? etMidnightMs(period) + toMin(SWING.end_hm) * 60000 : etMidnightMs(addDays(period, 1));
export const swapStartMs = (s0: Swap) => { const s = normSwap(s0); return periodStartMs(s.kind, s.covers.from); };
export const swapExpiresMs = (s0: Swap) => { const s = normSwap(s0); return periodEndMs(s.kind, s.covers.from); };
export const swapStatus = (s: Swap, nowMs: number): SwapStatus =>
  s.status === "pending" && nowMs >= swapExpiresMs(s) ? "expired" : s.status;
// When an accepted swap took effect. Null when it was decided before its first covered day began (it held
// from the start of that day); otherwise the decision time — the pod shows "from 10:42 AM" beside the swap
// mark so a mid-day acceptance never reads as if the whole day had been covered.
export const swapEffectiveAt = (s0: Swap): string | null => { const s = normSwap(s0); if (s.status !== "accepted" || !s.decided_at) return null; const d = Date.parse(s.decided_at); return Number.isFinite(d) && d > periodStartMs(s.kind, s.covers.from) ? s.decided_at : null; };

// Accepted swaps of a kind in decision order, computed once per call site: the sort key is a number
// (no localeCompare), because a poll replays this list for every day it renders.
export function acceptedSorted(kind: Kind, swaps: Swap[], nowMs: number): Swap[] {
  return swaps.map(normSwap).filter(s => s.kind === kind && swapStatus(s, nowMs) === "accepted")
    .map(s => ({ s, k: Date.parse(s.decided_at ?? "") || 0 }))
    .sort((a, b) => a.k - b.k || (a.s.id < b.s.id ? -1 : a.s.id > b.s.id ? 1 : 0)).map(x => x.s);
}
// Effective holder of ONE DAY: the base pick for that day's week, then accepted swaps whose range holds
// the day, in decision order. A swap moves its range from → to; its exchange moves that range to → from.
// A swap whose giver is no longer the holder that day (a later swap already moved it on) is skipped and
// reported rather than stacked blindly — the roster must never show someone covering a day they were
// swapped out of.
export function holderOn(kind: Kind, day: string, base: Person, swaps: Swap[], nowMs: number, accepted?: Swap[], overrides?: Override[]) {
  let holder: Person = base; let via: Swap | null = null; const skipped: Swap[] = []; let override: Override | null = null;
  for (const s of accepted ?? acceptedSorted(kind, swaps, nowMs)) {
    if (inRange(s.covers, day)) { if (samePerson(s.from, holder)) { holder = personOf(s.to); via = s; } else skipped.push(s); }
    else if (s.exchange && inRange(s.exchange.covers, day)) { if (samePerson(s.to, holder)) { holder = personOf(s.from); via = s; } else skipped.push(s); }
  }
  // A manager reassignment stands over any swap, and a later reassignment over an earlier one.
  for (const o of activeOverrides(overrides ?? [])) if (o.kind === kind && inRange(o.covers, day)) { holder = personOf(o.to); override = o; via = null; }
  return { holder, base, via, skipped, override };
}
// Whole-period view: the holder on the period's first day (a Saturday is one day; an on-call week's
// Monday). A split week is rendered from weekRuns, and the phone follows holderOn(today).
export function coverFor(kind: Kind, period: string, base: Person, swaps: Swap[], nowMs: number, overrides: Override[] = []) { return holderOn(kind, period, base, swaps, nowMs, undefined, overrides); }
export type Run = { from: string; to: string; name: string; ext: string; rc_id: string | null; email: string | null; swap_id: string | null; override_id: string | null; effective: string | null; days: number };
// One on-call week as consecutive runs of the same holder, Monday to Sunday. One run = an unsplit week.
export function weekRuns(monday: string, base: Person, swaps: Swap[], nowMs: number, accepted?: Swap[], overrides: Override[] = []): Run[] {
  const acc = accepted ?? acceptedSorted("oncall", swaps, nowMs); const runs: Run[] = [];
  for (const day of rangeDays(wholeWeek(monday))) {
    const h = holderOn("oncall", day, base, swaps, nowMs, acc, overrides); const last = runs[runs.length - 1];
    if (last && last.ext === h.holder.ext && last.swap_id === (h.via?.id ?? null) && last.override_id === (h.override?.id ?? null)) { last.to = addDays(day, 1); last.days++; }
    else runs.push({ from: day, to: addDays(day, 1), name: h.holder.name, ext: h.holder.ext, rc_id: h.holder.rc_id ?? null, email: h.holder.email ?? null, swap_id: h.via?.id ?? null, override_id: h.override?.id ?? null, effective: h.via ? swapEffectiveAt(h.via) : null, days: 1 });
  }
  return runs;
}
export const pendingOverlapping = (kind: Kind, r: DayRange, swaps: Swap[], nowMs: number): Swap | null =>
  swaps.map(normSwap).find(s => s.kind === kind && swapStatus(s, nowMs) === "pending" && (rangesOverlap(s.covers, r) || (!!s.exchange && rangesOverlap(s.exchange.covers, r)))) ?? null;
export const pendingFor = (kind: Kind, period: string, swaps: Swap[], nowMs: number) => pendingOverlapping(kind, wholePeriod(kind, period), swaps, nowMs);

// Every rule a request must pass, in the order a person would ask them. Throws with the reason.
export function validateRequest(a: { kind: Kind; week_start: string; covers: DayRange; exchange: { week_start: string; covers: DayRange } | null;
  requester: Party; counterparty: Person; pool: Person[]; swaps: Swap[]; nowMs: number; baseFor: (day: string) => Person; overrides?: Override[] }) {
  const ovr = activeOverrides(a.overrides ?? []);
  const wantDow = a.kind === "oncall" ? 1 : 6, dowName = a.kind === "oncall" ? "a Monday" : "a Saturday";
  if (!ISO.test(a.week_start) || isoDow(a.week_start) !== wantDow) throw new Error(`period must be ${dowName} as YYYY-MM-DD`);
  const whole = wholePeriod(a.kind, a.week_start);
  if (!ISO.test(a.covers.from) || !ISO.test(a.covers.to) || !(a.covers.from < a.covers.to)) throw new Error("the days to cover must be a range of at least one day (from < to)");
  if (a.kind === "swing" && !isWholePeriod("swing", a.week_start, a.covers)) throw new Error("a Saturday shift is swapped whole");
  if (a.covers.from < whole.from || a.covers.to > whole.to) throw new Error(`the days to cover must stay inside the week of Mon ${a.week_start} — a request never crosses a week boundary`);
  const label = rangeLabel(a.kind, a.week_start, a.covers);
  if (a.nowMs >= periodEndMs(a.kind, a.covers.from)) throw new Error(`${label} can no longer be swapped: ${a.kind === "swing" ? `the shift ended at ${SWING.end_hm}` : `${dowShort(a.covers.from)} ${a.covers.from} has ended`} — only a day that is still running, or a later one, can be swapped`);
  if (!a.pool.some(p => samePerson(p, a.requester))) throw new Error("you are not a member of this rotation");
  if (!a.pool.some(p => samePerson(p, a.counterparty))) throw new Error(`${a.counterparty.name} is not a member of this rotation`);
  if (samePerson(a.requester, a.counterparty)) throw new Error("you cannot swap with yourself");
  const acc = acceptedSorted(a.kind, a.swaps, a.nowMs);
  for (const day of rangeDays(a.covers)) {
    const cur = holderOn(a.kind, day, a.baseFor(day), a.swaps, a.nowMs, acc, ovr);
    if (!samePerson(cur.holder, a.requester)) throw new Error(`you do not hold ${dowShort(day)} ${day}; ${cur.holder.name} does`);
  }
  const pend = pendingOverlapping(a.kind, a.covers, a.swaps, a.nowMs);
  if (pend) throw new Error(`a request overlapping ${label} is already pending (${pend.from.name} → ${pend.to.name}); resolve it first`);
  if (a.exchange) {
    if (a.kind !== "oncall") throw new Error("only on-call swaps carry an exchange");
    const ex = a.exchange, exWhole = wholeWeek(ex.week_start);
    if (!ISO.test(ex.week_start) || isoDow(ex.week_start) !== 1) throw new Error("exchange must be a Monday as YYYY-MM-DD");
    if (!ISO.test(ex.covers.from) || !ISO.test(ex.covers.to) || !(ex.covers.from < ex.covers.to) || ex.covers.from < exWhole.from || ex.covers.to > exWhole.to) throw new Error("the exchange must be a range of days inside its own week");
    if (rangesOverlap(ex.covers, a.covers)) throw new Error("exchange must be different days");
    const exLabel = rangeLabel("oncall", ex.week_start, ex.covers);
    if (a.nowMs >= periodEndMs("oncall", ex.covers.from)) throw new Error(`${exLabel} can no longer be offered in exchange: ${dowShort(ex.covers.from)} ${ex.covers.from} has ended`);
    for (const day of rangeDays(ex.covers)) {
      const h = holderOn("oncall", day, a.baseFor(day), a.swaps, a.nowMs, acc, ovr);
      if (!samePerson(h.holder, a.counterparty)) throw new Error(`${a.counterparty.name} does not hold ${dowShort(day)} ${day}; ${h.holder.name} does`);
    }
    const pend2 = pendingOverlapping("oncall", ex.covers, a.swaps, a.nowMs);
    if (pend2) throw new Error(`a request overlapping ${exLabel} is already pending; resolve it first`);
  }
}

// Who may do what to a pending request. Enforced server-side on every call; the UI hiding a button is
// convenience, not security. `identity` null means the run had no end-user email — nothing is allowed.
export function authorizeDecision(swap: Swap, identity: Party | null, action: "accept" | "decline" | "cancel", cfg: RotationConfig, nowMs: number) {
  if (!identity) throw new Error("Your identity could not be established on this run (no end-user email), so nothing was changed.");
  const st = swapStatus(swap, nowMs);
  if (st !== "pending") throw new Error(`this request is ${st}, not pending`);
  if (action === "cancel") { if (!samePerson(swap.from, identity)) throw new Error(`only the requester, ${swap.from.name}, can cancel this request`); return; }
  if (swap.kind === "oncall") {
    if (!samePerson(swap.to, identity)) throw new Error(`only the counterparty, ${swap.to.name}, can ${action} this on-call swap`);
  } else {
    const ap = cfg.swing.approver;
    if (!ap) throw new Error("no Saturday swap approver is set in config (swing.approver)");
    if (!samePerson(ap, identity)) throw new Error(`only the Saturday approver, ${ap.name}, can ${action} this request`);
  }
}

export const swapView = (s0: Swap, nowMs: number) => { const s = normSwap(s0); return { ...s, status: swapStatus(s, nowMs), stored_status: s.status, starts_at: new Date(swapStartMs(s)).toISOString(), expires_at: new Date(swapExpiresMs(s)).toISOString(), effective_at: swapEffectiveAt(s),
  period: s.week_start, label: rangeLabel(s.kind, s.week_start, s.covers), whole: isWholePeriod(s.kind, s.week_start, s.covers),
  exchange_label: s.exchange ? rangeLabel("oncall", s.exchange.week_start, s.exchange.covers) : null }; };

// ---- manager override (phase 3) ------------------------------------------------------------------
// A rotation admin reassigns a week, a run of days or a Saturday with no counterparty consent — for
// sickness and no-shows. A SEPARATE record from a swap, with separate audit actions and separate cards:
// "<ENGINEER_4> reassigned <ENGINEER_8>'s Saturday" is not "<ENGINEER_4> approved <ENGINEER_8>'s request". holderOn applies overrides
// AFTER swaps, per day, and a later override wins. Pending requests overlapping the range close as
// superseded, and both their parties are told separately.
export type OverrideStatus = "active" | "cancelled";
export type Override = { id: string; kind: Kind; week_start: string; covers: DayRange;
  to: Party; displaced: Party; displaced_all: Party[]; reason: string;
  created_by: Party; created_at: string; status: OverrideStatus;
  cancelled_at: string | null; cancelled_by: Party | null; cancelled_reason: string | null;
  superseded_swap_ids: string[];
  notify?: { displaced?: NotifyResult[]; cover?: NotifyResult | null; cancel_displaced?: NotifyResult[]; cancel_cover?: NotifyResult | null } };
export const activeOverrides = (os: Override[]): Override[] => os.filter(o => o.status === "active")
  .map(o => ({ o, k: Date.parse(o.created_at) || 0 })).sort((a, b) => a.k - b.k || (a.o.id < b.o.id ? -1 : a.o.id > b.o.id ? 1 : 0)).map(x => x.o);
export const overrideView = (o: Override) => ({ ...o, label: rangeLabel(o.kind, o.week_start, o.covers), whole: isWholePeriod(o.kind, o.week_start, o.covers) });
export function applyOverride(args: { kind?: Kind; period?: string; covers_from?: string | null; covers_to?: string | null; counterparty_ext?: string; reason?: string | null },
  admin: Party | null, cfg: RotationConfig, swaps0: Swap[], overrides: Override[], now: EtNow): { override: Override; swaps: Swap[]; superseded: Swap[]; displaced: Person[] } {
  if (!admin) throw new Error("Your identity could not be established on this run (no end-user email), so nothing was changed.");
  const kind: Kind = args.kind === "swing" ? "swing" : "oncall";
  const sec = kind === "oncall" ? cfg.oncall : cfg.swing;
  const week_start = String(args.period ?? "");
  if (!ISO.test(week_start) || isoDow(week_start) !== (kind === "oncall" ? 1 : 6)) throw new Error(`period must be ${kind === "oncall" ? "a Monday" : "a Saturday"} as YYYY-MM-DD`);
  const whole = wholePeriod(kind, week_start);
  const covers: DayRange = args.covers_from && args.covers_to ? { from: String(args.covers_from), to: String(args.covers_to) } : whole;
  if (!ISO.test(covers.from) || !ISO.test(covers.to) || !(covers.from < covers.to)) throw new Error("the days to reassign must be a range of at least one day (from < to)");
  if (kind === "swing" && !isWholePeriod("swing", week_start, covers)) throw new Error("a Saturday shift is reassigned whole");
  if (covers.from < whole.from || covers.to > whole.to) throw new Error(`the days to reassign must stay inside the week of Mon ${week_start} — a reassignment never crosses a week boundary`);
  const label = rangeLabel(kind, week_start, covers);
  if (covers.to <= now.ymd) throw new Error(`${label} is over; only today and future days can be reassigned`);
  const reason = String(args.reason ?? "").trim().slice(0, 500);
  if (reason.length < 3) throw new Error("a reason is required to reassign coverage");
  const cover = sec.pool.find(p => p.ext === String(args.counterparty_ext ?? ""));
  if (!cover) throw new Error("pick the new cover from the rotation");
  const swaps = swaps0.map(normSwap);
  const acc = acceptedSorted(kind, swaps, now.ms), act = activeOverrides(overrides);
  const baseFor = (day: string) => pickRoster(sec.pool, sec.anchor, kind === "oncall" ? mondayOf(day) : day);
  const displaced: Person[] = [];
  for (const day of rangeDays(covers)) { const h = holderOn(kind, day, baseFor(day), swaps, now.ms, acc, act).holder; if (!samePerson(h, cover) && !displaced.some(p => samePerson(p, h))) displaced.push(h); }
  if (!displaced.length) throw new Error(`${cover.name} already covers ${label}`);
  let id = `ovr-${kind}-${covers.from}-${now.ms.toString(36)}-${overrides.length.toString(36)}`;
  while (overrides.some(o => o.id === id)) id += "x";
  const overlapping = swaps.filter(x => x.kind === kind && swapStatus(x, now.ms) === "pending" && (rangesOverlap(x.covers, covers) || (!!x.exchange && rangesOverlap(x.exchange.covers, covers))));
  const superseded: Swap[] = overlapping.map(x => ({ ...x, status: "superseded" as const, superseded_by: id, decided_at: now.iso, decided_by: admin, decided_reason: `superseded by a reassignment: ${reason}` }));
  const next = swaps.map(x => superseded.find(y => y.id === x.id) ?? x);
  const override: Override = { id, kind, week_start, covers, to: partyOf(cover), displaced: partyOf(displaced[0]), displaced_all: displaced.map(p => partyOf(p)), reason,
    created_by: admin, created_at: now.iso, status: "active", cancelled_at: null, cancelled_by: null, cancelled_reason: null, superseded_swap_ids: superseded.map(x => x.id), notify: {} };
  return { override, swaps: next, superseded, displaced };
}
export function cancelOverride(o: Override, admin: Party | null, reason: string | null | undefined, now: EtNow): Override {
  if (!admin) throw new Error("Your identity could not be established on this run (no end-user email), so nothing was changed.");
  if (o.status !== "active") throw new Error("this reassignment is already cancelled");
  const r = String(reason ?? "").trim().slice(0, 500);
  if (r.length < 3) throw new Error("a reason is required to cancel a reassignment");
  if (o.covers.to <= now.ymd) throw new Error(`${rangeLabel(o.kind, o.week_start, o.covers)} is over; the record stays as it was`);
  return { ...o, status: "cancelled", cancelled_at: now.iso, cancelled_by: admin, cancelled_reason: r };
}

// ---- on-call ------------------------------------------------------------------------------------
// A pending request on a period does not move the holder — mutual consent means nothing changes until
// both have agreed — but the row should say a request is open so the roster and the list agree.
export type PendingMark = { id: string; from: string; to: string } | null;
export const pendingMark = (kind: Kind, period: string, swaps: Swap[], nowMs: number): PendingMark => {
  const p = pendingFor(kind, period, swaps, nowMs);
  return p ? { id: p.id, from: p.from.name, to: p.to.name } : null;
};
export type OverrideMark = { id: string; by: string; reason: string; displaced: string; label: string } | null;
export const overrideMark = (o: Override | null | undefined): OverrideMark => o ? { id: o.id, by: o.created_by.name, reason: o.reason, displaced: o.displaced.name, label: rangeLabel(o.kind, o.week_start, o.covers) } : null;
export type Week = { week_start: string; week_end: string; name: string; ext: string; rc_id?: string | null; email?: string | null;
  base: Person; swap_id: string | null; swap_effective: string | null; override_id: string | null; override: OverrideMark; pending: PendingMark; runs: Run[]; split: boolean; as_of: string };

export function buildOncall(now: EtNow, oc: RotationConfig["oncall"], weeks: number = 4, swaps: Swap[] = [], overrides: Override[] = []) {
  const weekStart = mondayOf(now.ymd);
  const baseFor = (day: string) => pickRoster(oc.pool, oc.anchor, mondayOf(day));
  const acc = acceptedSorted("oncall", swaps, now.ms), act = activeOverrides(overrides);
  // A week's headline holder is whoever holds its reference day — today for the current week, Monday
  // otherwise. A split week carries every run and the pod renders them; the phone follows `today`.
  const weekOf = (ws: string): Week => {
    const asOf = ws === weekStart ? now.ymd : ws;
    const c = holderOn("oncall", asOf, baseFor(asOf), swaps, now.ms, acc, act);
    const runs = weekRuns(ws, baseFor(ws), swaps, now.ms, acc, act);
    return { week_start: ws, week_end: addDays(ws, 6), name: c.holder.name, ext: c.holder.ext, rc_id: c.holder.rc_id ?? null, email: c.holder.email ?? null,
      base: baseFor(ws), swap_id: c.via?.id ?? null, swap_effective: c.via ? swapEffectiveAt(c.via) : null, override_id: c.override?.id ?? null, override: overrideMark(c.override), pending: pendingMark("oncall", ws, swaps, now.ms), runs, split: runs.length > 1, as_of: asOf };
  };
  const current = weekOf(weekStart);
  const previous = weekOf(addDays(weekStart, -7));
  const upcoming = Array.from({ length: weeks }, (_, i) => weekOf(addDays(weekStart, 7 * (i + 1))));
  // Ten weeks ahead for the swap form: enough to find a week the requester holds and one the
  // counterparty holds, without rendering a wall in the pod.
  const horizon = Array.from({ length: 10 }, (_, i) => weekOf(addDays(weekStart, 7 * (i + 1))));
  const today = holderOn("oncall", now.ymd, baseFor(now.ymd), swaps, now.ms, acc, act);
  // Monday before 9:00 AM: RingCentral may legitimately still show last week's on-call. The drift
  // check reports that softly as "cutover pending" rather than as a mismatch; from 9:00 it is drift.
  const cutover_pending = now.dow === 1 && now.minutes < toMin(ONCALL.cutover_hm);
  return { ...ONCALL, current, previous, upcoming, horizon, cutover_pending, pool: oc.pool, cycle_weeks: oc.pool.length,
    today: { date: now.ymd, name: today.holder.name, ext: today.holder.ext, rc_id: today.holder.rc_id ?? null, email: today.holder.email ?? null, swap_id: today.via?.id ?? null, swap_effective: today.via ? swapEffectiveAt(today.via) : null, override_id: today.override?.id ?? null, override: overrideMark(today.override) },
    cto: oc.cto, cutover_due: `${weekStart}T${ONCALL.cutover_hm}:00`, sop_url: `${KB_LINK}/${ONCALL.sop_page}` };
}

// ---- RingCentral presence ------------------------------------------------------------------------
export type RcMember = { id: string | null; name: string; ext: string; acceptQueueCalls: boolean | null; acceptCurrentQueueCalls: boolean | null };
export type RcResult = { configured: boolean; ok: boolean; error: string | null; checked_at: string | null;
  members: RcMember[]; account: string | null; queue: string | null };

// Presence records come back as { records: [{ member: { id, extensionNumber, name }, acceptQueueCalls,
// acceptCurrentQueueCalls }] } (verified live 2026-09-10). Parsed defensively: a missing flag is null,
// never false — "unknown" and "refuses calls" are different findings.
export function normalizeRc(body: any): RcMember[] {
  const recs: any[] = Array.isArray(body?.records) ? body.records : Array.isArray(body) ? body : [];
  return recs.map(r => {
    const m = r?.member ?? r?.extension ?? {};
    return {
      id: m?.id != null ? String(m.id) : null,
      name: String(m?.name ?? "").trim(),
      ext: String(m?.extensionNumber ?? m?.extension_number ?? m?.extension?.extensionNumber ?? "").trim(),
      acceptQueueCalls: typeof r?.acceptQueueCalls === "boolean" ? r.acceptQueueCalls : null,
      acceptCurrentQueueCalls: typeof r?.acceptCurrentQueueCalls === "boolean" ? r.acceptCurrentQueueCalls : null,
    };
  });
}

type RcResource = { server_url?: string; client_id?: string; client_secret?: string; jwt?: string;
  username?: string; extension?: string; password?: string; account_id?: string; queue_id?: string };

const filled = (v: any) => typeof v === "string" && v.trim() !== "" && v !== "REPLACE_ME" && !v.startsWith("$var:");

// ---- RingCentral auth: ONE cached bearer, not one per poll ------------------------------------
// RingCentral allows 5 token mints per minute per app (auth group, verified 2026-09-11: HTTP 429 with
// x-rate-limit-remaining 0 after a handful of back-to-back `all` runs). Every poll used to mint its own
// token, so ten people watching the Schedule tab would have taken the drift check to "unknown" for
// everyone. The bearer (valid 3600 s) is cached in a secret workspace variable — the same pattern as
// f/rmm/ninja_token_cache — and re-minted two minutes before expiry or on a 401. Best effort: if the
// variable cannot be read or written the code mints as before.
const RC_TOKEN_VAR = "f/rmm/ringcentral_token_cache";
async function rcToken(rc: RcResource, server: string, signal: AbortSignal): Promise<{ token: string; expires_in: number }> {
  const body = filled(rc.jwt)
    ? new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: String(rc.jwt) })
    : filled(rc.username) && filled(rc.password)
      ? new URLSearchParams({ grant_type: "password", username: String(rc.username), password: String(rc.password),
          ...(filled(rc.extension) ? { extension: String(rc.extension) } : {}) })
      : null;
  if (!body) throw new Error("f/rmm/ringcentral has neither a jwt nor username/password — fill the secret variables");
  const basic = btoa(`${rc.client_id}:${rc.client_secret}`);
  const r = await fetch(`${server}/restapi/oauth/token`, { method: "POST", signal, body,
    headers: { authorization: `Basic ${basic}`, "content-type": "application/x-www-form-urlencoded", accept: "application/json" } });
  const j: any = await r.json().catch(() => ({}));
  if (!r.ok || !j?.access_token) throw new Error(`RingCentral auth failed (HTTP ${r.status}): ${j?.error_description ?? j?.error ?? j?.message ?? "no access_token"}`);
  return { token: String(j.access_token), expires_in: Number(j.expires_in) || 3600 };
}
async function rcBearer(rc: RcResource, server: string, signal: AbortSignal, fresh: boolean = false): Promise<string> {
  if (!fresh) {
    try {
      const raw = await (wmill as any).getVariable(RC_TOKEN_VAR);
      if (raw) { const c = JSON.parse(raw); const ttl = (Number(c?.expires_in) || 3600) * 1000;
        if (c?.token && c?.obtained_at && Date.now() - Number(c.obtained_at) < ttl - 120000) return String(c.token); }
    } catch (_) {}
  }
  const t = await rcToken(rc, server, signal);
  try {
    await (wmill as any).setVariable(RC_TOKEN_VAR, JSON.stringify({ token: t.token, obtained_at: Date.now(), expires_in: t.expires_in }), true,
      "Cached RingCentral bearer for the ops dashboard rotation runnable (queue presence + extension list); re-minted two minutes before expiry. RingCentral allows 5 mints/minute per app.");
  } catch (_) {}
  return t.token;
}
// GET with the cached bearer; one retry with a fresh token on 401. `what` names the call in errors.
async function rcGet(rc: RcResource, server: string, path: string, what: string, signal: AbortSignal): Promise<any> {
  const get = (token: string) => fetch(`${server}${path}`, { signal, headers: { authorization: `Bearer ${token}`, accept: "application/json" } });
  let r = await get(await rcBearer(rc, server, signal));
  if (r.status === 401) r = await get(await rcBearer(rc, server, signal, true));
  if (!r.ok) { const txt = await r.text().catch(() => ""); throw new Error(`RingCentral ${what} HTTP ${r.status}: ${txt.slice(0, 200)}`); }
  return r.json();
}
const rcServer = (rc: RcResource) => String(rc.server_url || "https://platform.ringcentral.com").replace(/\/$/, "");

export async function fetchQueuePresence(rc: RcResource, timeoutMs: number = 10000): Promise<{ members: RcMember[]; account: string; queue: string }> {
  const server = rcServer(rc);
  const account = String(rc.account_id || "");
  const queue = String(rc.queue_id || "");
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const j = await rcGet(rc, server, `/restapi/v1.0/account/${account}/call-queues/${queue}/presence`, "presence", ctl.signal);
    return { members: normalizeRc(j), account, queue };
  } finally { clearTimeout(timer); }
}

async function readRingCentral(): Promise<RcResult> {
  const out: RcResult = { configured: false, ok: false, error: null, checked_at: null, members: [], account: null, queue: null };
  let res: RcResource | null = null;
  try { res = await wmill.getResource("f/rmm/ringcentral"); } catch (_) { res = null; }
  if (!res || !filled(res.client_id) || !filled(res.client_secret)) {
    out.error = "RingCentral is not configured: resource f/rmm/ringcentral is missing or its client_id / client_secret variables are unset.";
    return out;
  }
  out.configured = true;
  try {
    const p = await fetchQueuePresence(res);
    return { ...out, ok: true, checked_at: new Date().toISOString(), members: p.members, account: p.account, queue: p.queue };
  } catch (e: any) {
    out.error = String(e?.message || e);
    return out;
  }
}

// ---- RingCentral user extensions + PSA agents → roster candidates --------------------------------
// The roster form adds people from this list only, so a row is complete by construction: the PSA
// agent supplies the identity email the swap flows match WM_END_USER_EMAIL against, the RingCentral
// extension supplies the ext and rc_id the drift check matches queue members on. Matched by email
// first (case-folded), then by normalised name. Anyone with only one half is listed with the reason
// they cannot be added, rather than accepted as a row that one of the two checks could never confirm.
export type RcExtension = { id: string; ext: string; name: string; email: string | null };
export type PsaAgent = { agent_id: number; name: string; email: string | null };
export type Candidate = { name: string; email: string | null; ext: string | null; rc_id: string | null; agent_id: number | null;
  ok: boolean; via: "email" | "name" | null; why: string | null };
export function matchPeople(agents: PsaAgent[], exts: RcExtension[]): Candidate[] {
  const byEmail = new Map(exts.filter(e => e.email).map(e => [norm(e.email!), e] as const));
  const byName = new Map(exts.map(e => [norm(e.name), e] as const));
  const used = new Set<string>();
  const out: Candidate[] = [];
  for (const a of agents) {
    const viaEmail = a.email ? byEmail.get(norm(a.email)) : undefined;
    const e = viaEmail ?? byName.get(norm(a.name)) ?? null;
    if (e && !used.has(e.id)) {
      used.add(e.id);
      const email = (a.email ?? e.email ?? "").toLowerCase() || null;
      out.push({ name: a.name, email, ext: e.ext, rc_id: e.id, agent_id: a.agent_id, ok: !!email, via: viaEmail ? "email" : "name",
        why: email ? null : "neither PSA nor RingCentral has an email for them — the swap flows could never match their login" });
    } else {
      out.push({ name: a.name, email: a.email ? a.email.toLowerCase() : null, ext: null, rc_id: null, agent_id: a.agent_id, ok: false, via: null,
        why: "no RingCentral extension matches this PSA agent by email or name — the drift check could never confirm them as on-call" });
    }
  }
  for (const e of exts) if (!used.has(e.id)) out.push({ name: e.name, email: e.email ? e.email.toLowerCase() : null, ext: e.ext, rc_id: e.id, agent_id: null, ok: false, via: null,
    why: "no PSA agent carries this email or name — identity for swaps and ticks is matched through the PSA agent" });
  return out.sort((x, y) => Number(y.ok) - Number(x.ok) || x.name.localeCompare(y.name));
}
export function normalizeRcExtensions(body: any): RcExtension[] {
  const recs: any[] = Array.isArray(body?.records) ? body.records : [];
  return recs.filter(r => (r?.type ?? "User") === "User" && (r?.status ?? "Enabled") === "Enabled")
    .map(r => ({ id: String(r.id), ext: String(r.extensionNumber ?? "").trim(), name: String(r.name ?? "").trim(), email: r?.contact?.email ? String(r.contact.email).trim() : null }))
    .filter(e => e.ext);
}
async function readRcExtensions(): Promise<{ ok: boolean; error: string | null; checked_at: string | null; extensions: RcExtension[] }> {
  let res: RcResource | null = null;
  try { res = await wmill.getResource("f/rmm/ringcentral"); } catch (_) { res = null; }
  if (!res || !filled(res.client_id) || !filled(res.client_secret)) return { ok: false, error: "RingCentral is not configured (resource f/rmm/ringcentral)", checked_at: null, extensions: [] };
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), 15000);
  try {
    const j = await rcGet(res, rcServer(res), `/restapi/v1.0/account/${String(res.account_id || "")}/extension?type=User&status=Enabled&perPage=1000`, "extension list", ctl.signal);
    return { ok: true, error: null, checked_at: new Date().toISOString(), extensions: normalizeRcExtensions(j) };
  } catch (e: any) { return { ok: false, error: String(e?.message || e), checked_at: null, extensions: [] }; }
  finally { clearTimeout(timer); }
}

// ---- drift ---------------------------------------------------------------------------------------
export type Finding = { level: "ok" | "warn" | "bad" | "info"; text: string };
export type Drift = { state: "ok" | "warn" | "bad" | "unknown"; headline: string; findings: Finding[];
  active: RcMember[]; expected_member: RcMember | null; exempt: RcMember[] };

// Matched on RingCentral id first (stable), then extension, then name (a roster may carry only names).
export const sameAs = (m: RcMember, p: Person) =>
  (!!p.rc_id && !!m.id && m.id === p.rc_id) || (!!p.ext && m.ext === p.ext) || (!!p.name && !!m.name && norm(m.name) === norm(p.name));
const who = (m: RcMember) => `${m.name || "unnamed member"}${m.ext ? ` (x${m.ext})` : ""}`;
// Who each queue member is to the rotation. The member table is evidence and lists everyone RingCentral
// returns; someone in neither the pool nor the CTO/exempt set — typically a person who left the
// rotation but was never removed from the queue — is tagged "none" so the table can mark them. They
// are never hidden, and they still count for the drift check: a leftover who is enabled is drift.
export type Membership = "pool" | "cto" | "exempt" | "none";
export const membershipOf = (m: RcMember, oc: RotationConfig["oncall"]): Membership =>
  sameAs(m, oc.cto) ? "cto" : oc.pool.some(p => sameAs(m, p)) ? "pool" : oc.drift_exempt.some(p => sameAs(m, p)) ? "exempt" : "none";

export function assessDrift(expected: Person, previous: Person, members: RcMember[], cutoverPending: boolean, exemptPeople: Person[] = []): Drift {
  // NAMED EXCEPTION. The CTO (and anyone else in drift_exempt) stays a queue member as standing
  // escalation, not as a rotation slot, so their enabled/disabled state says nothing about whether the
  // rotation was cut over. They are removed from the set the invariant is evaluated over — never the
  // extra enabled member, never flagged when disabled, never the "nobody" — and returned separately so
  // the member table can still show them, tagged exempt.
  const exempt = members.filter(m => exemptPeople.some(p => sameAs(m, p)));
  const considered = members.filter(m => !exempt.includes(m));
  const active = considered.filter(m => m.acceptCurrentQueueCalls === true);
  const expectedMember = considered.find(m => sameAs(m, expected)) ?? null;
  const findings: Finding[] = [];
  const exp = `${expected.name} (x${expected.ext})`;

  if (!members.length) {
    findings.push({ level: "bad", text: "RingCentral returned no members for the Tier 3 queue — the emergency line rings nobody." });
  } else if (!active.length) {
    findings.push({ level: "bad", text: "No rotation member has Accept Current Queue Calls on — the emergency line has no on-call Tier 3 engineer behind it." });
  }

  if (expectedMember && active.includes(expectedMember)) {
    if (expectedMember.acceptQueueCalls === false) {
      findings.push({ level: "bad", text: `${who(expectedMember)} is enabled for this queue but their extension is set to NOT accept queue calls — marked on-call, receiving nothing. Silent coverage failure: turn on Accept Queue Calls for the extension.` });
    } else {
      findings.push({ level: "ok", text: `RingCentral agrees with the roster: ${who(expectedMember)} is enabled for the queue and their extension accepts queue calls.` });
    }
  } else if (active.length) {
    const soleIsPrevious = active.length === 1 && sameAs(active[0], previous);
    if (soleIsPrevious && cutoverPending) {
      findings.push({ level: "warn", text: `Cutover pending: RingCentral still points at last week's on-call, ${who(active[0])}. The roster says ${exp} from this Monday; the switch is due by 9:00 AM.` });
    } else {
      findings.push({ level: "warn", text: `The roster says ${exp} is on-call, but RingCentral has ${active.map(who).join(", ")} enabled${soleIsPrevious ? " — last week's on-call was never cut over" : ""}.` });
    }
    if (!expectedMember) findings.push({ level: "warn", text: `${exp} is not a member of the queue at all.` });
    else if (expectedMember.acceptQueueCalls === false) findings.push({ level: "info", text: `${who(expectedMember)}'s extension is also set to not accept queue calls — enabling them for the queue alone would not restore coverage.` });
  } else if (members.length && !expectedMember) {
    findings.push({ level: "warn", text: `${exp} is not a member of the queue.` });
  }

  if (active.length > 1) {
    const extras = active.filter(m => m !== expectedMember);
    findings.push({ level: "warn", text: `${active.length} members are enabled for this queue; exactly one should be. Also enabled: ${extras.map(who).join(", ")}.` });
  }
  // Anyone else enabled for the queue whose extension refuses queue calls looks like cover and is not.
  for (const m of active) {
    if (m !== expectedMember && m.acceptQueueCalls === false) {
      findings.push({ level: "warn", text: `${who(m)} is enabled for this queue but their extension does not accept queue calls.` });
    }
  }

  const rank: Record<Finding["level"], number> = { ok: 0, info: 1, warn: 2, bad: 3 };
  const worst = findings.reduce<Finding["level"]>((w, f) => (rank[f.level] > rank[w] ? f.level : w), "ok");
  const state: Drift["state"] = worst === "bad" ? "bad" : worst === "warn" ? "warn" : "ok";
  const headline = state === "ok" ? "Roster and RingCentral agree"
    : state === "warn" ? (findings.some(f => f.text.startsWith("Cutover pending")) ? "Cutover pending" : "RingCentral disagrees with the roster")
    : active.some(m => m.acceptQueueCalls === false) ? "Silent coverage failure" : "No on-call is taking queue calls";
  return { state, headline, findings, active, expected_member: expectedMember, exempt };
}

// ---- Saturday swing ----------------------------------------------------------------------------
export type Sat = { date: string; name: string; ext: string; email?: string | null; status: string; base: Person; swap_id: string | null; swap_effective: string | null; override_id: string | null; override: OverrideMark; pending: PendingMark };

export function buildSwing(now: EtNow, sw: RotationConfig["swing"], weeks: number = 4, swaps: Swap[] = [], overrides: Override[] = []) {
  const startMin = toMin(SWING.start_hm), endMin = toMin(SWING.end_hm);
  // "Next N Saturdays" includes today while today's shift has not ended; after 1 PM it is history.
  let first = saturdayOnOrAfter(now.ymd);
  if (first === now.ymd && now.minutes >= endMin) first = addDays(first, 7);
  const baseFor = (d: string) => pickRoster(sw.pool, sw.anchor, d);
  const acc = acceptedSorted("swing", swaps, now.ms), act = activeOverrides(overrides);
  const satOf = (date: string, i: number): Sat => {
    const c = holderOn("swing", date, baseFor(date), swaps, now.ms, acc, act);
    const status = date === now.ymd ? (now.minutes < startMin ? "today" : "in_progress") : i === 0 ? "next" : "upcoming";
    return { date, name: c.holder.name, ext: c.holder.ext, email: c.holder.email ?? null, status, base: baseFor(date), swap_id: c.via?.id ?? null, swap_effective: c.via ? swapEffectiveAt(c.via) : null, override_id: c.override?.id ?? null, override: overrideMark(c.override),
      pending: pendingMark("swing", date, swaps, now.ms) };
  };
  const saturdays = Array.from({ length: weeks }, (_, i) => satOf(addDays(first, 7 * i), i));
  const horizon = Array.from({ length: 10 }, (_, i) => satOf(addDays(first, 7 * i), i));
  const approver = sw.approver;
  return { ...SWING, saturdays, horizon, pool: sw.pool, anchor: sw.anchor, effective_from: sw.effective_from, sop_url: `${KB_LINK}/${SWING.sop_page}`,
    approval: { model: "single" as const, approver,
      text: approver ? `Swap requests need ${approver.name}${approver.ext ? ` (x${approver.ext})` : ""} to approve.` : "Swap approver for the Saturday rotation is not set in config." } };
}

// ---- shift-start checklist: a server-side record ---------------------------------------------------
// Ticks live in automation_config (key ops_swing_checklist) per Saturday, per tech, one timestamp per
// tick — the same key + audit-row pattern as the roster and the swaps; nothing is kept in the browser.
// Only the EFFECTIVE holder of that Saturday (after swaps) may tick, decided here from the job's
// end-user email; everyone else, approver and admins included, reads the record.
// WINDOW: opens at the shift start (8:00 AM Saturday) and closes Monday 8:00 AM ET. Why that rule:
// a tech who forgot to tick before leaving can still record the shift over the weekend, and because
// every tick carries its own timestamp a Sunday tick reads as a Sunday tick — the history marks ticks
// after 1:00 PM "late" rather than presenting them as done on time. Once the next working week starts
// the record is read-only for everyone, so a Saturday cannot be backfilled after a manager has looked
// at it or a month later. The alternative (locking at 1:00 PM) turns "forgot to tick" into "no record",
// which is a worse record than "ticked late"; the other alternative (never locking) makes the record
// worthless as evidence.
export const CHK_KEY = "ops_swing_checklist";
export const CHK_CLOSE_HM = "08:00";   // on the Monday after
export type ChkRecord = { name: string; email: string | null; ext: string; ticks: Record<string, string>; updated_at: string };
export type ChkStore = { saturdays: Record<string, Record<string, ChkRecord>> };
export type ChkWindow = "not_open" | "open" | "closed";
export const chkWindow = (date: string, nowMs: number): ChkWindow => {
  const opens = etMidnightMs(date) + toMin(SWING.start_hm) * 60000;
  const closes = etMidnightMs(addDays(date, 2)) + toMin(CHK_CLOSE_HM) * 60000;
  return nowMs < opens ? "not_open" : nowMs >= closes ? "closed" : "open";
};
export const chkRecord = (store: ChkStore | null | undefined, date: string, ext: string): ChkRecord | null => store?.saturdays?.[date]?.[ext] ?? null;
export function chkSummary(rec: ChkRecord | null, total: number, date: string) {
  // Only items that exist count: a tick stored for an item since removed from the list (the handoff
  // was item 6 until 2026-09-11) is kept in the record but neither shown nor scored.
  const ticks: Record<string, string> = Object.fromEntries(Object.entries(rec?.ticks ?? {}).filter(([k]) => Number(k) >= 1 && Number(k) <= total));
  const times = Object.values(ticks).map(t => Date.parse(t)).filter(Number.isFinite).sort((a, b) => a - b);
  const shiftEnd = etMidnightMs(date) + toMin(SWING.end_hm) * 60000;
  return { done: Object.keys(ticks).length, total, ticks,
    first_at: times.length ? new Date(times[0]).toISOString() : null, last_at: times.length ? new Date(times[times.length - 1]).toISOString() : null,
    late: times.filter(t => t > shiftEnd).length };
}
export function applyTick(store: ChkStore | null, date: string, holder: Person, identity: Party | null, n: number, on: boolean, nowMs: number, total: number): ChkStore {
  if (!identity) throw new Error("Your identity could not be established on this run (no end-user email), so nothing was recorded.");
  if (!ISO.test(date) || isoDow(date) !== 6) throw new Error("period must be a Saturday as YYYY-MM-DD");
  if (!samePerson(holder, identity)) throw new Error(`only ${holder.name}, who covers Sat ${date}, can tick this checklist`);
  const w = chkWindow(date, nowMs);
  if (w === "not_open") throw new Error(`the checklist for Sat ${date} opens at ${SWING.start_hm} that morning`);
  if (w === "closed") throw new Error(`the record for Sat ${date} closed Monday ${CHK_CLOSE_HM} and stays as it was`);
  if (!Number.isInteger(n) || n < 1 || n > total) throw new Error(`item must be 1..${total}`);
  const s: ChkStore = { saturdays: { ...(store?.saturdays ?? {}) } };
  const day = { ...(s.saturdays[date] ?? {}) };
  const prev: ChkRecord = day[holder.ext] ?? { name: holder.name, email: holder.email ?? identity.email ?? null, ext: holder.ext, ticks: {}, updated_at: "" };
  const ticks = { ...prev.ticks };
  if (on) ticks[String(n)] = new Date(nowMs).toISOString(); else delete ticks[String(n)];
  day[holder.ext] = { ...prev, ticks, updated_at: new Date(nowMs).toISOString() };
  s.saturdays[date] = day;
  return s;
}
// Manager view: the last N Saturdays already worked — who covered (after swaps), what they ticked and
// when, and what PSA saw them do that day. `assigned, 0/6, no PSA actions` is the row that matters
// and is flagged no_evidence; Saturdays before swing.effective_from with no record are left out and
// counted (historyOmitted): a name computed from a roster that did not apply then is not evidence.
export type Activity = { date: string; agent_id: number; actions: number; tickets: number; first_at: string | null; last_at: string | null };
export const HISTORY_DAYS = 90;   // past Saturdays and swap history both read this far back
// Saturdays already worked, most recent first, back to the window's floor. Today's counts once its shift is over.
export function passedSaturdays(now: EtNow, days: number = HISTORY_DAYS): string[] {
  let last = saturdayOnOrAfter(now.ymd);
  if (!(last === now.ymd && now.minutes >= toMin(SWING.end_hm))) last = addDays(last, -7);
  const floor = addDays(now.ymd, -days);
  const out: string[] = [];
  for (let i = 0; ; i++) { const d = addDays(last, -7 * i); if (d < floor) break; out.push(d); }
  return out;
}

// ---- who actually covered a Saturday: a SNAPSHOT, taken once the shift has ended --------------------------
// History used to recompute past holders from the CURRENT roster, so a roster change silently rewrote the
// past (Sep 5 read "<ENGINEER_13>" when <ENGINEER_7> worked it). The effective holder is now recorded once a Saturday has
// passed — the identity-snapshotting rule already used for swap parties — and history reads the record,
// never recomputes. Three write moments, all idempotent (a recorded date is never overwritten):
//   (1) every `all` / `swing` run freezes any passed Saturday without a record from the roster and swaps
//       as they stand — the first poll after 1:00 PM does it;
//   (2) every `set` freezes every passed Saturday without a record under the roster being REPLACED,
//       before the new one is saved — so a roster change can never rewrite the past;
//   (3) a checklist record wins over both: only the effective holder can tick, so a record under an
//       extension is proof of who held the day.
// Saturdays before swing.effective_from are not frozen (this roster did not apply) unless somebody
// ticked; they stay "before this roster" in history. Blob-based (automation_config, key
// ops_swing_coverage) until the storage tables land as ops_saturday_coverage.
export const COVERAGE_KEY = "ops_swing_coverage";
export type CoverageSnap = { name: string; email: string | null; ext: string; rc_id: string | null; agent_id: number | null;
  base_name: string; swap_id: string | null; swap_reason: string | null;
  source: "roster" | "swap" | "checklist" | "backfill" | "override"; recorded_at: string; job_id: string | null; reason: string | null;
  override_id?: string | null;
  // PSA activity cached at freeze time (phase 5): null until cached.
  actions?: number | null; tickets?: number | null; first_action?: string | null; last_action?: string | null; activity_as_of?: string | null };
export type CoverageStore = { saturdays: Record<string, CoverageSnap> };
export function snapshotFor(date: string, sw: RotationConfig["swing"], swaps: Swap[], chk: ChkStore | null, agentOf: (p: Person) => number | null, now: EtNow, jobId: string | null, overrides: Override[] = [], activity: Activity[] = []): CoverageSnap {
  // The day's PSA activity, if the caller already has it, rides on the record (provisional until a week later).
  const cache = (agent_id: number | null) => { const a = agent_id != null ? activity.find(x => x.date === date && x.agent_id === agent_id) : null; return a ? { actions: a.actions, tickets: a.tickets, first_action: a.first_at, last_action: a.last_at, activity_as_of: now.iso } : {}; };
  const c = coverFor("swing", date, pickRoster(sw.pool, sw.anchor, date), swaps, now.ms, overrides);
  const day = chk?.saturdays?.[date] ?? {};
  const ticked = Object.entries(day).find(([, r]) => Object.keys(r?.ticks ?? {}).length > 0);
  const common = { base_name: c.base.name, swap_id: c.via?.id ?? null, swap_reason: c.via?.decided_reason ?? null, recorded_at: now.iso, job_id: jobId,
    override_id: c.override?.id ?? null, reason: c.override ? `reassigned by ${c.override.created_by.name}: ${c.override.reason}` : null };
  if (ticked) {
    const [ext, r] = ticked; const row = sw.pool.find(p => p.ext === ext);
    const person: Person = { name: r.name, email: r.email ?? null, ext, rc_id: row?.rc_id ?? null };
    const aid = agentOf(person);
    return { name: r.name, email: r.email ?? null, ext, rc_id: row?.rc_id ?? null, agent_id: aid, source: "checklist", ...common, ...cache(aid) };
  }
  const aid = agentOf(c.holder);
  return { name: c.holder.name, email: c.holder.email ?? null, ext: c.holder.ext, rc_id: c.holder.rc_id ?? null, agent_id: aid, source: c.override ? "override" : c.via ? "swap" : "roster", ...common, ...cache(aid) };
}
export function freezeCoverage(store: CoverageStore | null, sw: RotationConfig["swing"], swaps: Swap[], now: EtNow, chk: ChkStore | null,
  agentOf: (p: Person) => number | null, jobId: string | null, days: number = HISTORY_DAYS, overrides: Override[] = [], activity: Activity[] = []): { store: CoverageStore; frozen: string[] } {
  const s: CoverageStore = { saturdays: { ...(store?.saturdays ?? {}) } };
  const frozen: string[] = [];
  for (const date of passedSaturdays(now, days)) {
    if (s.saturdays[date]) continue;
    const ticked = Object.values(chk?.saturdays?.[date] ?? {}).some(r => Object.keys(r?.ticks ?? {}).length > 0);
    if (date < sw.effective_from && !ticked) continue;
    s.saturdays[date] = snapshotFor(date, sw, swaps, chk, agentOf, now, jobId, overrides, activity);
    frozen.push(date);
  }
  return { store: s, frozen };
}

// Manager view: the last 90 days of Saturdays — who covered (from the RECORD), what they ticked and when,
// and what PSA saw them do that day. `assigned, 0/5, no PSA actions` is the row that matters and is
// flagged no_evidence. A Saturday with no record is recomputed from the current roster and marked so —
// never judged; before swing.effective_from it is "before this roster".
export type Activity = { date: string; agent_id: number; actions: number; tickets: number; first_at: string | null; last_at: string | null };
export type HistoryFlag = "no_evidence" | "no_ticks" | "no_actions" | "ok" | "unmatched" | "recomputed";
export type HistorySource = "record" | "checklist" | "backfill" | "recomputed";
export type HistoryRow = { date: string; name: string; ext: string; email: string | null; agent_id: number | null; recorded: boolean; source: HistorySource; reason: string | null;
  swap_id: string | null; swap_reason: string | null; swap_from: string | null;
  done: number; total: number; first_tick: string | null; last_tick: string | null; late: number;
  actions: number | null; tickets: number | null; first_action: string | null; last_action: string | null; flag: HistoryFlag };
export function buildHistory(now: EtNow, sw: RotationConfig["swing"], swaps: Swap[], store: ChkStore | null, activity: Activity[],
  agentOf: (p: Person) => number | null, days: number = HISTORY_DAYS, coverage: CoverageStore | null = null): HistoryRow[] {
  const total = SWING.checklist.length;
  const rows: HistoryRow[] = [];
  for (const date of passedSaturdays(now, days)) {
    const snap = coverage?.saturdays?.[date] ?? null;
    if (!snap && date < sw.effective_from) continue;   // no record and the roster did not apply then: not listed, counted by historyOmitted
    const c = snap ? null : coverFor("swing", date, pickRoster(sw.pool, sw.anchor, date), swaps, now.ms);
    const h: Person = snap ? { name: snap.name, ext: snap.ext, email: snap.email, rc_id: snap.rc_id } : c!.holder;
    const recorded = !!snap;
    const source: HistorySource = snap ? (snap.source === "backfill" ? "backfill" : snap.source === "checklist" ? "checklist" : "record") : "recomputed";
    const sum = chkSummary(chkRecord(store, date, h.ext), total, date);
    const agent_id = snap?.agent_id ?? agentOf(h);
    // Live numbers win while the Saturday is fresh; otherwise the cache on the coverage row (taken at freeze,
    // finalised a week later) — so a poll only asks PSA about Saturdays that are not yet final.
    const live = agent_id != null ? activity.find(a => a.date === date && a.agent_id === agent_id) ?? null : null;
    const cached = snap?.activity_as_of && snap.actions != null ? { actions: snap.actions, tickets: snap.tickets ?? 0, first_at: snap.first_action ?? null, last_at: snap.last_action ?? null } : null;
    const act = live ?? cached;
    const actions = agent_id == null && !cached ? null : act?.actions ?? 0;
    const flag: HistoryFlag = !recorded ? "recomputed" : agent_id == null ? "unmatched"
      : sum.done === 0 && actions === 0 ? "no_evidence" : sum.done === 0 ? "no_ticks" : actions === 0 ? "no_actions" : "ok";
    rows.push({ date, name: h.name, ext: h.ext, email: h.email ?? null, agent_id, recorded, source, reason: snap?.reason ?? null,
      swap_id: snap ? snap.swap_id : c!.via?.id ?? null, swap_reason: snap ? snap.swap_reason : c!.via?.decided_reason ?? null,
      swap_from: snap ? (snap.swap_id ? snap.base_name : null) : (c!.via ? c!.via.from.name : null),
      done: sum.done, total, first_tick: sum.first_at, last_tick: sum.last_at, late: sum.late,
      actions, tickets: agent_id == null && !cached ? null : act?.tickets ?? 0, first_action: act?.first_at ?? null, last_action: act?.last_at ?? null, flag });
  }
  return rows;
}
// A coverage record's activity cache is final once it was taken a week or more after the Saturday.
export const activityFinal = (c: CoverageSnap | null | undefined, date: string): boolean =>
  !!c?.activity_as_of && c.actions != null && Date.parse(c.activity_as_of) >= etMidnightMs(addDays(date, 7));
// Saturdays in the window that predate swing.effective_from and have no record: not listed (a holder
// computed from today's roster is not evidence of who worked then), but counted so the table can say
// how many it leaves out and for which dates. A recorded Saturday — backfilled included — is never omitted.
export type HistoryOmitted = { count: number; first: string | null; last: string | null };
export function historyOmitted(now: EtNow, sw: RotationConfig["swing"], coverage: CoverageStore | null = null, days: number = HISTORY_DAYS): HistoryOmitted {
  const dates = passedSaturdays(now, days).filter(d => d < sw.effective_from && !coverage?.saturdays?.[d]);   // most recent first
  return { count: dates.length, first: dates.length ? dates[dates.length - 1] : null, last: dates.length ? dates[0] : null };
}

// ---- Teams notification for swap requests -------------------------------------------------------
// LATENCY, NOT COVERAGE. The dashboard is the system of record and pending requests are always visible
// in the pod, so this only shortens the wait: a failure is recorded on the swap and shown next to it,
// and never blocks or fails the request. Transport is a webhook URL in the resource
// f/rmm/teams_saturday_swaps (url is a $var reference to a secret variable). kind "power_automate" posts
// an Adaptive Card in the envelope the Teams Workflows app's "When a Teams webhook request is received"
// trigger expects — the supported successor to Office 365 connectors, which Microsoft retired in May
// 2026. kind "n8n" or "generic" posts the plain event for the receiver to format. No Graph, no bot,
// no app registration. Both rotations, three events each (request, decision, cancel).
export type TeamsResource = { url?: string; kind?: string; dashboard_url?: string; enabled?: boolean };
export type NotifyResult = { at: string; ok: boolean; kind: string | null; error: string | null };
export const DASHBOARD_URL = "https://<WINDMILL_HOST>/apps/get/f/rmm/ops_dashboard?workspace=<WORKSPACE>";
// The card button lands on Schedule → Shift Schedule with the pod the card is about in view. The app reads
// tab / mode / pod from the page URL (window.parent, since it runs in a blob: iframe); a plain visit is unchanged.
export const podUrl = (base: string, kind: Kind) => `${base}${base.includes("?") ? "&" : "?"}tab=schedule&mode=shifts&pod=${kind}`;
export type SwapEvent = { event: "request" | "decision" | "cancel" | "superseded" | "override"; kind: Kind; title: string; summary: string; facts: { name: string; value: string }[];
  url: string; swap_id: string | null; override_id?: string | null; status: string; recipients: { role: string; name: string; email: string | null; ext: string | null }[] };
const whoIs = (p: Party | Person | null | undefined) => p ? `${p.name}${p.ext ? ` (x${p.ext})` : ""}` : "—";
const periodLabel = (s: Swap) => rangeLabel(s.kind, s.week_start, s.covers);
const exchangeLabel = (s: Swap) => s.exchange ? rangeLabel("oncall", s.exchange.week_start, s.exchange.covers) : "";
const recip = (role: string, p: Party | Person | null | undefined) => p ? [{ role, name: p.name, email: p.email ?? null, ext: p.ext ?? null }] : [];
// Who each message is FOR. On-call (mutual consent): a request goes to the counterparty who must
// accept; a decision goes back to the requester; a cancel goes to the counterparty so a dead request
// does not sit in their head. Saturday (single approver): the approver stands in the counterparty's
// place for request and cancel; the decision goes to the requester. The webhook posts to one place —
// the recipients list lets a flow route to a person's chat when it is built to do that.
export function swapEvent(event: "request" | "decision" | "cancel", s0: Swap, approver: Person | null, dashboardUrl: string = DASHBOARD_URL): SwapEvent {
  const s = normSwap(s0);
  const per = periodLabel(s);
  const thePer = s.kind === "oncall" && !isWholePeriod("oncall", s.week_start, s.covers) ? per : `the ${per}`;
  const theEx = s.exchange ? (isWholePeriod("oncall", s.exchange.week_start, s.exchange.covers) ? `the ${exchangeLabel(s)}` : exchangeLabel(s)) : "";
  const what = s.kind === "oncall" ? "On-call swap" : "Saturday swap";
  const facts: { name: string; value: string }[] = [
    { name: s.kind === "oncall" ? (isWholePeriod("oncall", s.week_start, s.covers) ? "Week" : "Days") : "Saturday", value: per },
    { name: "Requested by", value: whoIs(s.from) },
    { name: "Covered by", value: whoIs(s.to) },
  ];
  if (s.kind === "oncall" && s.exchange) facts.push({ name: "In exchange for", value: `${exchangeLabel(s)}, covered by ${s.from.name}` });
  if (s.note) facts.push({ name: "Note", value: s.note });
  const decider = s.kind === "oncall" ? recip("counterparty", s.to) : recip("approver", approver);
  if (event === "request") {
    facts.push({ name: s.kind === "oncall" ? "Waiting on" : "Approver", value: s.kind === "oncall" ? whoIs(s.to) : whoIs(approver) }, { name: "Requested", value: s.requested_at });
    return { event, kind: s.kind, swap_id: s.id, status: s.status, url: podUrl(dashboardUrl, s.kind), recipients: decider, title: `${what} request · ${per}`, facts,
      summary: s.kind === "oncall"
        ? `${s.from.name} asks ${s.to.name} to cover ${thePer}${s.exchange ? `, offering ${theEx} in return` : ""}. Accept or decline in the Operations Dashboard → Schedule → Tier 3 On-Call.`
        : `${s.from.name} asks for ${s.to.name} to cover ${per}. Approve or decline in the Operations Dashboard → Schedule → Saturday Swing Shift.` };
  }
  if (event === "cancel") {
    facts.push({ name: "Withdrawn by", value: whoIs(s.decided_by ?? s.from) }, { name: "Withdrawn", value: s.decided_at ?? "" });
    if (s.decided_reason) facts.push({ name: "Reason", value: s.decided_reason });
    return { event, kind: s.kind, swap_id: s.id, status: s.status, url: podUrl(dashboardUrl, s.kind), recipients: decider, title: `${what} request withdrawn · ${per}`, facts,
      summary: `${s.from.name} withdrew the request for ${s.to.name} to cover ${thePer}. Nothing changes and nothing is waiting on you.` };
  }
  const verb = s.status === "accepted" ? (s.kind === "oncall" ? "accepted" : "approved") : s.status === "declined" ? "declined" : s.status;
  facts.push({ name: verb.charAt(0).toUpperCase() + verb.slice(1) + " by", value: whoIs(s.decided_by) }, { name: "Reason", value: s.decided_reason || (s.kind === "oncall" ? "none given" : "—") }, { name: "Decided", value: s.decided_at ?? "" });
  return { event, kind: s.kind, swap_id: s.id, status: s.status, url: podUrl(dashboardUrl, s.kind), recipients: recip("requester", s.from), title: `${what} ${verb} · ${per}`, facts,
    summary: `${s.to.name} ${s.status === "accepted" ? "covers" : "does not cover"} ${thePer} for ${s.from.name} — ${verb} by ${s.decided_by?.name ?? (s.kind === "oncall" ? s.to.name : "the approver")}${s.decided_reason ? `: ${s.decided_reason}` : ""}.` };
}
// The Workflows app posts whatever card the webhook carries; buttons render only as Action.OpenUrl.
export function adaptiveCard(ev: SwapEvent): any {
  return { type: "message", attachments: [{ contentType: "application/vnd.microsoft.card.adaptive", contentUrl: null, content: {
    $schema: "http://adaptivecards.io/schemas/adaptive-card.json", type: "AdaptiveCard", version: "1.4",
    body: [
      { type: "TextBlock", size: "Medium", weight: "Bolder", text: ev.title, wrap: true },
      { type: "TextBlock", text: ev.summary, wrap: true },
      { type: "TextBlock", size: "Small", isSubtle: true, wrap: true, text: `For ${ev.recipients.length ? ev.recipients.map(r => `${r.name} (${r.role})`).join(", ") : "the team"}` },
      { type: "FactSet", facts: ev.facts.map(f => ({ title: f.name, value: f.value })) },
    ],
    actions: [{ type: "Action.OpenUrl", title: "Open the Operations Dashboard", url: ev.url }],
  } }] };
}
// power_automate: the Teams Workflows envelope (type + attachments, which the "post each adaptive card"
// template iterates) with the event fields alongside it — so a flow can route on
// triggerBody()?['recipients'][0]['email'] instead of posting everything to one channel. n8n / generic:
// the plain event plus the card, for the receiver to format.
export function notifyPayload(kind: string | undefined, ev: SwapEvent): any {
  const meta = { source: "ops_dashboard/rotation", event: ev.event, kind: ev.kind, swap_id: ev.swap_id, override_id: ev.override_id ?? null, status: ev.status, title: ev.title, summary: ev.summary, url: ev.url, recipients: ev.recipients, facts: ev.facts };
  return (kind ?? "power_automate") === "power_automate" ? { ...meta, ...adaptiveCard(ev) } : { ...meta, card: adaptiveCard(ev) };
}
// Override cards: one per recipient. The wording must read as a reassignment, never as an accepted swap —
// the recipient did not agree to anything.
export function overrideEvent(which: "displaced" | "cover" | "cancelled", o: Override, recipient: Party | Person, role: "displaced" | "cover", dashboardUrl: string = DASHBOARD_URL): SwapEvent {
  const what = o.kind === "oncall" ? "On-call" : "Saturday"; const per = rangeLabel(o.kind, o.week_start, o.covers);
  const facts: { name: string; value: string }[] = [
    { name: "Rotation", value: what }, { name: o.kind === "oncall" ? "Days" : "Saturday", value: per },
    { name: "Displaced", value: o.displaced_all.map(p => whoIs(p)).join(", ") }, { name: "Now covers", value: whoIs(o.to) },
    { name: "Reason", value: o.reason }, { name: "Reassigned by", value: whoIs(o.created_by) }, { name: "When", value: o.created_at },
  ];
  if (which === "cancelled") facts.push({ name: "Cancelled by", value: whoIs(o.cancelled_by) }, { name: "Cancelled", value: o.cancelled_at ?? "" }, { name: "Cancellation reason", value: o.cancelled_reason ?? "" });
  const who = o.displaced_all.map(p => p.name).join(" and ");
  const title = which === "cancelled" ? `${what} reassignment cancelled · ${per}` : `${what} REASSIGNMENT · ${per}`;
  const summary = which === "displaced"
    ? `${o.created_by.name} reassigned ${per} from you to ${o.to.name}. This is a manager reassignment, not a swap you agreed to — you are no longer covering ${per}. Reason: ${o.reason}.`
    : which === "cover"
      ? `${o.created_by.name} reassigned ${per} to you; ${who} had it. This is a manager reassignment, not a swap — nobody asked you to accept it, and the roster already shows you. Reason: ${o.reason}.`
      : `${o.cancelled_by?.name ?? "A rotation admin"} cancelled the reassignment of ${per} (${o.displaced.name} → ${o.to.name}); coverage returns to the roster and accepted swaps. Reason: ${o.cancelled_reason ?? ""}.`;
  return { event: "override", kind: o.kind, swap_id: null, override_id: o.id, status: o.status, url: podUrl(dashboardUrl, o.kind), recipients: recip(role, recipient), title, summary, facts };
}
// A pending request closed by a reassignment: each party gets its own card, and it says nothing is waiting on them.
export function supersededEvent(s0: Swap, o: Override, recipient: Party, role: "requester" | "counterparty", dashboardUrl: string = DASHBOARD_URL): SwapEvent {
  const s = normSwap(s0); const what = s.kind === "oncall" ? "On-call" : "Saturday"; const per = periodLabel(s);
  const facts = [ { name: s.kind === "oncall" ? "Days" : "Saturday", value: per }, { name: "Requested by", value: whoIs(s.from) }, { name: "Was to be covered by", value: whoIs(s.to) },
    { name: "Superseded by", value: `${o.created_by.name} reassigning ${rangeLabel(o.kind, o.week_start, o.covers)} to ${o.to.name}` }, { name: "Reason", value: o.reason }, { name: "Closed", value: s.decided_at ?? "" } ];
  return { event: "superseded", kind: s.kind, swap_id: s.id, override_id: o.id, status: s.status, url: podUrl(dashboardUrl, s.kind), recipients: recip(role, recipient), title: `${what} swap request superseded · ${per}`, facts,
    summary: `The request for ${s.to.name} to cover ${per} for ${s.from.name} was closed: ${o.created_by.name} reassigned ${rangeLabel(o.kind, o.week_start, o.covers)} to ${o.to.name}. Nothing is waiting on you. Reason: ${o.reason}.` };
}
// The one poster: reads the resource, builds the event with its dashboard URL, posts, never throws.
async function postTeams(build: (dashboardUrl: string) => SwapEvent): Promise<NotifyResult> {
  const at = new Date().toISOString();
  let res: TeamsResource | null = null;
  try { res = await wmill.getResource("f/rmm/teams_saturday_swaps"); } catch (_) { res = null; }
  if (!res) return { at, ok: false, kind: null, error: "not configured — resource f/rmm/teams_saturday_swaps is missing" };
  if (res.enabled === false) return { at, ok: false, kind: res.kind ?? null, error: "disabled in resource f/rmm/teams_saturday_swaps" };
  if (!filled(res.url) || !/^https:\/\//i.test(String(res.url))) return { at, ok: false, kind: res.kind ?? null, error: "not configured — resource f/rmm/teams_saturday_swaps has no https url (secret variable f/rmm/teams_saturday_swaps_webhook)" };
  const ev = build(filled(res.dashboard_url) ? String(res.dashboard_url) : DASHBOARD_URL);
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(), 8000);
  try {
    const r = await fetch(String(res.url), { method: "POST", signal: ctl.signal, headers: { "content-type": "application/json" }, body: JSON.stringify(notifyPayload(res.kind, ev)) });
    if (!r.ok) { const txt = await r.text().catch(() => ""); return { at, ok: false, kind: res.kind ?? null, error: `HTTP ${r.status}${txt ? ": " + txt.slice(0, 160) : ""}` }; }
    return { at, ok: true, kind: res.kind ?? null, error: null };
  } catch (e: any) { return { at, ok: false, kind: res.kind ?? null, error: String(e?.name === "AbortError" ? "timed out after 8 s" : e?.message || e) }; }
  finally { clearTimeout(timer); }
}
async function notifyOverride(o: Override, phase: "set" | "cancel") {
  const displaced: NotifyResult[] = [];
  for (const p of o.displaced_all) displaced.push(await postTeams(url => overrideEvent(phase === "set" ? "displaced" : "cancelled", o, p, "displaced", url)));
  const cover = await postTeams(url => overrideEvent(phase === "set" ? "cover" : "cancelled", o, o.to, "cover", url));
  return phase === "set" ? { displaced, cover } : { cancel_displaced: displaced, cancel_cover: cover };
}
async function notifySuperseded(s: Swap, o: Override): Promise<NotifyResult[]> {
  const out: NotifyResult[] = [];
  for (const [role, p] of [["requester", s.from], ["counterparty", s.to]] as const) out.push(await postTeams(url => supersededEvent(s, o, p, role, url)));
  return out;
}
async function notifyTeams(event: "request" | "decision" | "cancel", s: Swap, approver: Person | null): Promise<NotifyResult> {
  return postTeams(url => swapEvent(event, s, approver, url));
}

// ---- identity ------------------------------------------------------------------------------------
// The viewer, from the job's end-user email → psa_agent by email. `party` is null only when the run
// carried no end-user email at all (CLI preview, schedule); an email with no PSA agent still counts as
// an identity — pool rows may carry that email — but has no agent id. Roles are derived against the
// pools by samePerson (email, then extension, then name).
export type Viewer = { email: string | null; party: Party | null; note: string | null;
  oncall_member: Person | null; swing_member: Person | null; swing_approver: boolean;
  is_admin: boolean; admin_note: string | null; admins: AdminPerson[] };
export function viewerRoles(party: Party | null, cfg: RotationConfig): Pick<Viewer, "oncall_member" | "swing_member" | "swing_approver"> {
  if (!party) return { oncall_member: null, swing_member: null, swing_approver: false };
  return { oncall_member: cfg.oncall.pool.find(p => samePerson(p, party)) ?? null,
    swing_member: cfg.swing.pool.find(p => samePerson(p, party)) ?? null,
    swing_approver: !!cfg.swing.approver && samePerson(cfg.swing.approver, party) };
}
// ---- admin gate (Plan 3) -------------------------------------------------------------------------
// Who may change the rotation config and apply overrides: the members of the Windmill group
// rotation_admins. The list lives in Windmill (Workspace → Groups, edited by workspace admins) — not in
// automation_config and not in the roster form — so the people it governs cannot add themselves through
// the dashboard. An empty or unreadable group switches every admin capability OFF; it never widens.
// The check is server-side from WM_END_USER_EMAIL; the UI only renders the answer.
export const ADMIN_GROUP = "rotation_admins";
export type AdminPerson = { email: string; name: string | null };
export type AdminList = { admins: AdminPerson[]; note: string | null };
export const isAdmin = (email: string | null | undefined, admins: { email: string }[]): boolean =>
  !!email && admins.some(a => String(a.email).toLowerCase() === String(email).toLowerCase());
export const adminFields = (email: string | null | undefined, adm: AdminList): Pick<Viewer, "is_admin" | "admin_note" | "admins"> =>
  ({ is_admin: isAdmin(email, adm.admins), admin_note: adm.note, admins: adm.admins });
export function adminGate(v: Pick<Viewer, "email" | "is_admin" | "admin_note" | "admins">, what: string): void {
  if (v.is_admin) return;
  const who = v.admins.length ? v.admins.map(a => a.name ?? a.email).join(", ") : "nobody yet";
  throw new Error(`${what} is limited to rotation admins — the Windmill group ${ADMIN_GROUP} (${who}), which workspace admins edit under Workspace → Groups. `
    + (v.email ? `${v.email} is not a member.` : "This run carries no end-user email.") + (v.admin_note ? ` ${v.admin_note}` : ""));
}
// Reads the group through the workspace API with the job's own token (the app runs on behalf of u/admin).
async function readAdmins(): Promise<AdminList> {
  const off = (why: string): AdminList => ({ admins: [], note: `Admin group ${ADMIN_GROUP} ${why} — admin actions are off.` });
  const base = process.env.BASE_INTERNAL_URL ?? process.env.BASE_URL ?? process.env.WM_BASE_URL, ws = process.env.WM_WORKSPACE, token = process.env.WM_TOKEN;
  if (!base || !ws || !token) return off("could not be read (no Windmill API context on this run)");
  try {
    const h = { Authorization: `Bearer ${token}` };
    const g = await fetch(`${base}/api/w/${ws}/groups/get/${ADMIN_GROUP}`, { headers: h });
    if (g.status === 404) return off("does not exist in this workspace; a workspace admin creates it under Workspace → Groups");
    if (!g.ok) return off(`could not be read (HTTP ${g.status})`);
    const grp: any = await g.json();
    const members: string[] = Array.isArray(grp?.members) ? grp.members.map((m: any) => String(m)) : [];
    if (!members.length) return off("has no members");
    const u = await fetch(`${base}/api/w/${ws}/users/list`, { headers: h });
    if (!u.ok) return off(`members could not be resolved to logins (HTTP ${u.status})`);
    const users: any[] = await u.json();
    const admins = users.filter(x => members.includes(String(x.username)) && !x.disabled).map(x => ({ email: String(x.email).toLowerCase(), name: null as string | null }));
    return admins.length ? { admins, note: null } : off("has no enabled members");
  } catch (e: any) { return off(`could not be read (${String(e?.message || e)})`); }
}
// Display names for the admin list: the roster rows first, PSA second, the email otherwise.
async function namedAdmins(sql: any, cfg: RotationConfig, adm: AdminList): Promise<AdminList> {
  if (!adm.admins.length) return adm;
  const people: Person[] = [...cfg.oncall.pool, cfg.oncall.cto, ...cfg.swing.pool, ...(cfg.swing.approver ? [cfg.swing.approver] : [])];
  const byEmail = new Map<string, string>(); for (const p of people) if (p.email) byEmail.set(p.email.toLowerCase(), p.name);
  const missing = adm.admins.filter(a => !byEmail.has(a.email)).map(a => a.email);
  if (missing.length) { try { for (const r of await sql`select name, lower(email) email from psa_agent where lower(email) = any(${missing}::text[]) and deleted_at is null order by is_disabled`) if (!byEmail.has(r.email)) byEmail.set(r.email, String(r.name)); } catch (_) {} }
  return { admins: adm.admins.map(a => ({ email: a.email, name: byEmail.get(a.email) ?? null })), note: adm.note };
}
async function resolveIdentity(sql: any, cfg: RotationConfig, adm: AdminList = { admins: [], note: null }): Promise<Viewer> {
  const email = jobActor().end_user_email;
  if (!email) return { email: null, party: null, note: "No end-user email on this run — swaps are read-only here.", ...viewerRoles(null, cfg), ...adminFields(null, adm) };
  let party: Party = { agent_id: null, name: "", email, ext: null };
  let note: string | null = null;
  try {
    const rows = await sql`select agent_id::int agent_id, name, lower(email) email from psa_agent where lower(email) = ${email} and deleted_at is null order by is_disabled, agent_id limit 1`;
    if (rows.length) party = { agent_id: Number(rows[0].agent_id), name: String(rows[0].name), email, ext: null };
    else note = `No PSA agent carries ${email}; matched to the rotation by email only.`;
  } catch (e: any) { note = `PSA agent lookup failed (${String(e?.message || e)}); matched to the rotation by email only.`; }
  // Fill the party's extension from the pool row it matches, so stored swap parties always carry one.
  const match = cfg.oncall.pool.find(p => samePerson(p, party)) ?? cfg.swing.pool.find(p => samePerson(p, party)) ?? (cfg.swing.approver && samePerson(cfg.swing.approver, party) ? cfg.swing.approver : null);
  if (match) party = { ...party, name: party.name || match.name, ext: match.ext, rc_id: match.rc_id ?? null };
  return { email, party, note, ...viewerRoles(party, cfg), ...adminFields(email, adm) };
}

// ---- storage: tables first, blobs second (one release) ------------------------------------------------
// Rows live in rmm_automation tables created by f/rmm/ops_rotation_migrate (ops_swap, ops_checklist_tick,
// ops_saturday_coverage): identity snapshots on every row, no foreign keys to psa_agent or the pools,
// 18-month retention pruned weekly, the pods reading 90 days. Until the tables exist — or they exist but
// the old automation_config blobs have not been migrated — the blobs are read and written as before and
// the Settings panel says so. storage_migrate (rotation admins) copies the blobs, verifies counts and a
// spot-check into automation_audit, and drops the blobs only when every count matches.
export const STORAGE_KEY = "ops_rotation_storage";
export const RETENTION_DAYS = 548;          // 18 months
const READ_BACK_DAYS = HISTORY_DAYS + 14;   // the 90-day windows plus slack for weeks that straddle it
export type Storage = { mode: "table" | "blob"; note: string | null; tables: boolean; blobs: string[]; migrated_at: string | null };
async function storageMode(sql: any): Promise<Storage> {
  let tables = false;
  try { const r = await sql`select to_regclass('public.ops_swap') a, to_regclass('public.ops_checklist_tick') b, to_regclass('public.ops_saturday_coverage') c, to_regclass('public.ops_override') d`; tables = !!(r[0]?.a && r[0]?.b && r[0]?.c && r[0]?.d); } catch (_) {}
  let blobs: string[] = [];
  try { blobs = (await sql`select key from automation_config where key in (${SWAPS_KEY}, ${CHK_KEY}, ${COVERAGE_KEY}) order by key`).map((r: any) => String(r.key)); } catch (_) {}
  if (!tables) return { mode: "blob", note: "the rotation tables do not exist yet (f/rmm/ops_rotation_migrate has not run here) — reading and writing the automation_config blobs", tables, blobs, migrated_at: null };
  let marker: any = null; try { marker = await readKey(sql, STORAGE_KEY); } catch (_) {}
  if (marker?.migrated_at) return { mode: "table", note: null, tables, blobs, migrated_at: String(marker.migrated_at) };
  if (blobs.length) return { mode: "blob", note: `the tables exist but the blobs (${blobs.join(", ")}) have not been migrated — a rotation admin runs Settings → Rotation roster → Migrate storage`, tables, blobs, migrated_at: null };
  return { mode: "table", note: null, tables, blobs, migrated_at: null };
}
const rangeSql = (r: DayRange) => `[${r.from},${r.to})`;
const parseRange = (v: any): DayRange => { const m = /^\[(\d{4}-\d{2}-\d{2}),(\d{4}-\d{2}-\d{2})\)$/.exec(String(v ?? "")); if (!m) throw new Error(`unreadable daterange ${String(v)}`); return { from: m[1], to: m[2] }; };
const ymdOf = (v: any): string => v instanceof Date ? v.toISOString().slice(0, 10) : String(v).slice(0, 10);
const isoOf = (v: any): string | null => v == null ? null : v instanceof Date ? v.toISOString() : new Date(v).toISOString();
const audit = async (sql: any, action: string, actor: string, detail: any) => { try { await sql`insert into automation_audit (actor, action, device_id, detail) values (${actor}, ${action}, null, ${sql.json(detail)})`; } catch (_) {} };
function rowToSwap(r: any): Swap {
  const party = (p: string): Party => ({ agent_id: r[`${p}_agent_id`] != null ? Number(r[`${p}_agent_id`]) : null, name: String(r[`${p}_name`] ?? ""), email: r[`${p}_email`] ?? null, ext: r[`${p}_ext`] ?? null, rc_id: r[`${p}_rc_id`] ?? null });
  return { id: String(r.id), kind: r.kind, week_start: ymdOf(r.week_start), covers: parseRange(r.covers),
    exchange: r.exchange_covers ? { week_start: ymdOf(r.exchange_week_start), covers: parseRange(r.exchange_covers) } : null,
    from: party("from"), to: party("to"), note: String(r.note ?? ""), status: r.status,
    requested_at: isoOf(r.requested_at)!, decided_at: isoOf(r.decided_at), decided_by: r.decided_by_name ? party("decided_by") : null,
    decided_reason: r.decided_reason ?? null, notify: r.notify ?? {}, superseded_by: r.superseded_by ?? null };
}
async function readSwaps(sql: any, st: Storage, now: EtNow = etNow()): Promise<Swap[]> {
  if (st.mode === "table") {
    const cutoff = addDays(now.ymd, -READ_BACK_DAYS);
    const rows = await sql`select * from ops_swap where week_start >= ${cutoff}::date or exchange_week_start >= ${cutoff}::date order by requested_at, id`;
    return rows.map(rowToSwap);
  }
  try { const v = await readKey(sql, SWAPS_KEY); return Array.isArray(v?.swaps) ? v.swaps.map(normSwap) : []; } catch (_) { return []; }
}
async function saveSwap(sql: any, st: Storage, s: Swap, all: Swap[], action: string, actor: string, detail: any) {
  if (st.mode !== "table") { await upsertKey(sql, SWAPS_KEY, { swaps: all }, action, actor, detail); return; }
  try {
    await sql`insert into ops_swap (id, kind, week_start, covers, exchange_week_start, exchange_covers,
        from_agent_id, from_name, from_email, from_ext, from_rc_id, to_agent_id, to_name, to_email, to_ext, to_rc_id,
        note, status, requested_at, decided_at, decided_by_agent_id, decided_by_name, decided_by_email, decided_by_ext, decided_reason, notify, superseded_by)
      values (${s.id}, ${s.kind}, ${s.week_start}::date, ${rangeSql(s.covers)}::daterange, ${s.exchange?.week_start ?? null}::date, ${s.exchange ? rangeSql(s.exchange.covers) : null}::daterange,
        ${s.from.agent_id}, ${s.from.name}, ${s.from.email}, ${s.from.ext}, ${s.from.rc_id ?? null}, ${s.to.agent_id}, ${s.to.name}, ${s.to.email}, ${s.to.ext}, ${s.to.rc_id ?? null},
        ${s.note}, ${s.status}, ${s.requested_at}::timestamptz, ${s.decided_at}::timestamptz, ${s.decided_by?.agent_id ?? null}, ${s.decided_by?.name ?? null}, ${s.decided_by?.email ?? null}, ${s.decided_by?.ext ?? null},
        ${s.decided_reason ?? null}, ${sql.json(s.notify ?? {})}, ${s.superseded_by ?? null})
      on conflict (id) do update set status = excluded.status, decided_at = excluded.decided_at, decided_by_agent_id = excluded.decided_by_agent_id, decided_by_name = excluded.decided_by_name,
        decided_by_email = excluded.decided_by_email, decided_by_ext = excluded.decided_by_ext, decided_reason = excluded.decided_reason, notify = excluded.notify, superseded_by = excluded.superseded_by`;
  } catch (e: any) {
    if (e?.code === "23P01") throw new Error("another request overlapping those days was recorded at the same moment; refresh and try again");
    throw e;
  }
  await audit(sql, action, actor, detail);
}
async function readChk(sql: any, st: Storage, now: EtNow = etNow()): Promise<ChkStore | null> {
  if (st.mode === "table") {
    const cutoff = addDays(now.ymd, -READ_BACK_DAYS);
    const rows = await sql`select saturday, tech_ext, tech_name, tech_email, item, ticked_at from ops_checklist_tick where saturday >= ${cutoff}::date order by saturday, tech_ext, item`;
    const store: ChkStore = { saturdays: {} };
    for (const r of rows) {
      const d = ymdOf(r.saturday), ext = String(r.tech_ext);
      const day = (store.saturdays[d] ??= {});
      const rec = (day[ext] ??= { name: String(r.tech_name), email: r.tech_email ?? null, ext, ticks: {}, updated_at: "" });
      const at = isoOf(r.ticked_at)!; rec.ticks[String(r.item)] = at; if (at > rec.updated_at) rec.updated_at = at;
    }
    return store;
  }
  try { const v = await readKey(sql, CHK_KEY); return v && typeof v === "object" && v.saturdays ? v as ChkStore : null; } catch (_) { return null; }
}
async function saveTick(sql: any, st: Storage, date: string, rec: ChkRecord, n: number, on: boolean, nowMs: number, next: ChkStore, action: string, actor: string, detail: any) {
  if (st.mode !== "table") { await upsertKey(sql, CHK_KEY, next, action, actor, detail); return; }
  if (on) await sql`insert into ops_checklist_tick (saturday, tech_ext, item, tech_name, tech_email, ticked_at, job_id)
      values (${date}::date, ${rec.ext}, ${n}, ${rec.name}, ${rec.email}, ${new Date(nowMs).toISOString()}::timestamptz, ${jobActor().job_id})
      on conflict (saturday, tech_ext, item) do update set ticked_at = excluded.ticked_at, job_id = excluded.job_id`;
  else await sql`delete from ops_checklist_tick where saturday = ${date}::date and tech_ext = ${rec.ext} and item = ${n}`;
  await audit(sql, action, actor, detail);
}
function rowToSnap(r: any): CoverageSnap {
  return { name: String(r.name), email: r.email ?? null, ext: String(r.ext), rc_id: r.rc_id ?? null, agent_id: r.agent_id != null ? Number(r.agent_id) : null,
    base_name: String(r.base_name), swap_id: r.swap_id ?? null, swap_reason: r.swap_reason ?? null, source: r.source, recorded_at: isoOf(r.recorded_at)!, job_id: r.job_id ?? null, reason: r.reason ?? null,
    override_id: r.override_id ?? null, actions: r.actions != null ? Number(r.actions) : null, tickets: r.tickets != null ? Number(r.tickets) : null,
    first_action: isoOf(r.first_action), last_action: isoOf(r.last_action), activity_as_of: isoOf(r.activity_as_of) };
}
async function readCoverage(sql: any, st: Storage, now: EtNow = etNow()): Promise<CoverageStore | null> {
  if (st.mode === "table") {
    const cutoff = addDays(now.ymd, -READ_BACK_DAYS);
    const rows = await sql`select * from ops_saturday_coverage where saturday >= ${cutoff}::date order by saturday`;
    const store: CoverageStore = { saturdays: {} };
    for (const r of rows) store.saturdays[ymdOf(r.saturday)] = rowToSnap(r);
    return store;
  }
  try { const v = await readKey(sql, COVERAGE_KEY); return v && typeof v === "object" && v.saturdays ? v as CoverageStore : null; } catch (_) { return null; }
}
// A record is written once and never overwritten (on conflict do nothing) — the same rule the blob kept.
async function saveCoverage(sql: any, st: Storage, store: CoverageStore, dates: string[], action: string, actor: string, detail: any) {
  if (st.mode !== "table") { await upsertKey(sql, COVERAGE_KEY, store, action, actor, detail); return; }
  for (const d of dates) {
    const c = store.saturdays[d]; if (!c) continue;
    await sql`insert into ops_saturday_coverage (saturday, name, email, ext, rc_id, agent_id, base_name, swap_id, swap_reason, source, override_id, reason, recorded_at, job_id, actions, tickets, first_action, last_action, activity_as_of)
      values (${d}::date, ${c.name}, ${c.email}, ${c.ext}, ${c.rc_id}, ${c.agent_id}, ${c.base_name}, ${c.swap_id}, ${c.swap_reason}, ${c.source}, ${c.override_id ?? null}, ${c.reason}, ${c.recorded_at}::timestamptz, ${c.job_id},
        ${c.actions ?? null}, ${c.tickets ?? null}, ${c.first_action ?? null}::timestamptz, ${c.last_action ?? null}::timestamptz, ${c.activity_as_of ?? null}::timestamptz)
      on conflict (saturday) do nothing`;
  }
  await audit(sql, action, actor, detail);
}
function rowToOverride(r: any): Override {
  const party = (p: string): Party => ({ agent_id: r[`${p}_agent_id`] != null ? Number(r[`${p}_agent_id`]) : null, name: String(r[`${p}_name`] ?? ""), email: r[`${p}_email`] ?? null, ext: r[`${p}_ext`] ?? null, rc_id: r[`${p}_rc_id`] ?? null });
  return { id: String(r.id), kind: r.kind, week_start: ymdOf(r.week_start), covers: parseRange(r.covers), to: party("to"), displaced: party("displaced"),
    displaced_all: Array.isArray(r.displaced_all) ? r.displaced_all : [party("displaced")], reason: String(r.reason ?? ""), created_by: party("created_by"), created_at: isoOf(r.created_at)!,
    status: r.status, cancelled_at: isoOf(r.cancelled_at), cancelled_by: r.cancelled_by_name ? { agent_id: null, name: String(r.cancelled_by_name), email: r.cancelled_by_email ?? null, ext: null } : null,
    cancelled_reason: r.cancelled_reason ?? null, superseded_swap_ids: Array.isArray(r.superseded_swap_ids) ? r.superseded_swap_ids.map(String) : [], notify: r.notify ?? {} };
}
async function readOverrides(sql: any, st: Storage, now: EtNow = etNow()): Promise<Override[]> {
  if (st.mode !== "table") return [];
  const cutoff = addDays(now.ymd, -READ_BACK_DAYS);
  const rows = await sql`select * from ops_override where week_start >= ${cutoff}::date order by created_at, id`;
  return rows.map(rowToOverride);
}
async function saveOverride(sql: any, o: Override, action: string, actor: string, detail: any) {
  await sql`insert into ops_override (id, kind, week_start, covers, to_agent_id, to_name, to_email, to_ext, to_rc_id, displaced_agent_id, displaced_name, displaced_email, displaced_ext, displaced_rc_id, displaced_all,
      reason, created_by_agent_id, created_by_name, created_by_email, created_by_ext, created_at, status, cancelled_at, cancelled_by_name, cancelled_by_email, cancelled_reason, superseded_swap_ids, notify)
    values (${o.id}, ${o.kind}, ${o.week_start}::date, ${rangeSql(o.covers)}::daterange, ${o.to.agent_id}, ${o.to.name}, ${o.to.email}, ${o.to.ext}, ${o.to.rc_id ?? null},
      ${o.displaced.agent_id}, ${o.displaced.name}, ${o.displaced.email}, ${o.displaced.ext}, ${o.displaced.rc_id ?? null}, ${sql.json(o.displaced_all)},
      ${o.reason}, ${o.created_by.agent_id}, ${o.created_by.name}, ${o.created_by.email}, ${o.created_by.ext}, ${o.created_at}::timestamptz, ${o.status},
      ${o.cancelled_at}::timestamptz, ${o.cancelled_by?.name ?? null}, ${o.cancelled_by?.email ?? null}, ${o.cancelled_reason ?? null}, ${o.superseded_swap_ids}::text[], ${sql.json(o.notify ?? {})})
    on conflict (id) do update set status = excluded.status, cancelled_at = excluded.cancelled_at, cancelled_by_name = excluded.cancelled_by_name, cancelled_by_email = excluded.cancelled_by_email,
      cancelled_reason = excluded.cancelled_reason, notify = excluded.notify`;
  await audit(sql, action, actor, detail);
}
// The presence writer's own audit rows (rc_presence_write / rc_presence_restore / rc_presence_skipped), newest first.
async function readWriterRuns(sql: any, limit: number = 10): Promise<WriterRun[]> {
  try {
    const rows = await sql`select id, ts, action, actor, detail->>'trigger' trigger, detail->'holder'->>'name' holder, (detail->>'ok')::boolean ok, jsonb_array_length(coalesce(detail->'changes', '[]'::jsonb)) changes
      from automation_audit where action in ('rc_presence_write', 'rc_presence_restore', 'rc_presence_skipped') order by ts desc limit ${limit}`;
    return rows.map((r: any) => ({ id: Number(r.id), ts: isoOf(r.ts)!, action: String(r.action), actor: String(r.actor ?? ""), trigger: r.trigger ?? null, holder: r.holder ?? null, ok: r.ok == null ? null : !!r.ok, changes: r.changes == null ? null : Number(r.changes) }));
  } catch (_) { return []; }
}
// Run the writer as its own job (it is a workspace script, so the schedule and the app share one implementation).
// Fire-and-forget for event triggers; wait for the result when an admin presses the button.
async function runWriter(args: Record<string, any>, wait: boolean): Promise<any> {
  const base = `${process.env.BASE_INTERNAL_URL ?? process.env.BASE_URL ?? process.env.WM_BASE_URL}/api/w/${process.env.WM_WORKSPACE}`;
  const r = await fetch(`${base}/jobs/${wait ? "run_wait_result" : "run"}/p/${WRITER_SCRIPT}`, { method: "POST", headers: { Authorization: `Bearer ${process.env.WM_TOKEN}`, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  const t = await r.text();
  if (!r.ok) throw new Error(`presence writer: HTTP ${r.status} ${t.slice(0, 200)}`);
  try { return JSON.parse(t); } catch (_) { return t.replace(/"/g, "").trim(); }
}
// After an accepted on-call swap or a reassignment: if the range touches today, roll the phone now. Best effort.
async function kickWriter(trigger: string, covers: DayRange, today: string): Promise<string | null> {
  if (!inRange(covers, today)) return null;
  try { const id = await runWriter({ trigger, mode: "apply" }, false); return typeof id === "string" ? id : null; } catch (_) { return null; }
}
// 18-month retention, applied when a Saturday is frozen (weekly). Counts go to the audit log.
async function pruneRetention(sql: any, st: Storage, now: EtNow, actor: string) {
  if (st.mode !== "table") return null;
  const cutoff = addDays(now.ymd, -RETENTION_DAYS);
  try {
    const a = await sql`delete from ops_swap where week_start < ${cutoff}::date and (exchange_week_start is null or exchange_week_start < ${cutoff}::date)`;
    const b = await sql`delete from ops_checklist_tick where saturday < ${cutoff}::date`;
    const c = await sql`delete from ops_saturday_coverage where saturday < ${cutoff}::date`;
    const d = await sql`delete from ops_override where week_start < ${cutoff}::date`;
    const counts = { swaps: Number(a.count ?? 0), ticks: Number(b.count ?? 0), coverage: Number(c.count ?? 0), overrides: Number(d.count ?? 0) };
    if (counts.swaps + counts.ticks + counts.coverage + counts.overrides > 0) await audit(sql, "ops_rotation_prune", actor, { cutoff, ...counts });
    return counts;
  } catch (_) { return null; }
}
// Copy the blobs into the tables, verify, cut over. Idempotent: rows already present are left alone.
async function migrateBlobs(sql: any, st: Storage, now: EtNow, actor: string) {
  if (!st.tables) throw new Error("the rotation tables do not exist yet — f/rmm/ops_rotation_migrate must run first (db_migrate_all applies it every 15 minutes)");
  if (st.mode === "table" && st.migrated_at && !st.blobs.length) return { ok: true, counts: { swaps: { blob: 0, table: 0 }, ticks: { blob: 0, table: 0 }, coverage: { blob: 0, table: 0 } }, spot: {}, migrated_at: st.migrated_at, note: `already migrated ${st.migrated_at}; nothing to do` };
  const [sv, kv, cv] = await Promise.all([readKey(sql, SWAPS_KEY), readKey(sql, CHK_KEY), readKey(sql, COVERAGE_KEY)]);
  const swaps: Swap[] = Array.isArray(sv?.swaps) ? sv.swaps.map(normSwap) : [];
  const chk: ChkStore["saturdays"] = kv?.saturdays ?? {};
  const cov: Record<string, CoverageSnap> = cv?.saturdays ?? {};
  for (const s of swaps) {
    await sql`insert into ops_swap (id, kind, week_start, covers, exchange_week_start, exchange_covers,
        from_agent_id, from_name, from_email, from_ext, from_rc_id, to_agent_id, to_name, to_email, to_ext, to_rc_id,
        note, status, requested_at, decided_at, decided_by_agent_id, decided_by_name, decided_by_email, decided_by_ext, decided_reason, notify, superseded_by)
      values (${s.id}, ${s.kind}, ${s.week_start}::date, ${rangeSql(s.covers)}::daterange, ${s.exchange?.week_start ?? null}::date, ${s.exchange ? rangeSql(s.exchange.covers) : null}::daterange,
        ${s.from.agent_id}, ${s.from.name}, ${s.from.email}, ${s.from.ext}, ${s.from.rc_id ?? null}, ${s.to.agent_id}, ${s.to.name}, ${s.to.email}, ${s.to.ext}, ${s.to.rc_id ?? null},
        ${s.note ?? ""}, ${s.status}, ${s.requested_at}::timestamptz, ${s.decided_at}::timestamptz, ${s.decided_by?.agent_id ?? null}, ${s.decided_by?.name ?? null}, ${s.decided_by?.email ?? null}, ${s.decided_by?.ext ?? null},
        ${s.decided_reason ?? null}, ${sql.json(s.notify ?? {})}, ${s.superseded_by ?? null})
      on conflict (id) do nothing`;
  }
  const ticks: { d: string; ext: string; item: number; at: string; name: string; email: string | null }[] = [];
  for (const [d, day] of Object.entries(chk)) for (const [ext, rec] of Object.entries(day ?? {})) for (const [item, at] of Object.entries(rec?.ticks ?? {})) ticks.push({ d, ext, item: Number(item), at: String(at), name: rec.name, email: rec.email ?? null });
  for (const t of ticks) await sql`insert into ops_checklist_tick (saturday, tech_ext, item, tech_name, tech_email, ticked_at, job_id) values (${t.d}::date, ${t.ext}, ${t.item}, ${t.name}, ${t.email}, ${t.at}::timestamptz, 'migrated') on conflict (saturday, tech_ext, item) do nothing`;
  for (const [d, c] of Object.entries(cov)) await sql`insert into ops_saturday_coverage (saturday, name, email, ext, rc_id, agent_id, base_name, swap_id, swap_reason, source, reason, recorded_at, job_id)
      values (${d}::date, ${c.name}, ${c.email}, ${c.ext}, ${c.rc_id}, ${c.agent_id}, ${c.base_name}, ${c.swap_id}, ${c.swap_reason}, ${c.source}, ${c.reason}, ${c.recorded_at}::timestamptz, ${c.job_id}) on conflict (saturday) do nothing`;
  // Verify: every blob item has its row, and a spot-check of one record per kind reads back the same.
  const ids = swaps.map(s => s.id);
  const swapsIn = ids.length ? Number((await sql`select count(*)::int n from ops_swap where id = any(${ids}::text[])`)[0].n) : 0;
  let ticksIn = 0; for (const t of ticks) ticksIn += Number((await sql`select count(*)::int n from ops_checklist_tick where saturday = ${t.d}::date and tech_ext = ${t.ext} and item = ${t.item}`)[0].n);
  const covDates = Object.keys(cov);
  const covIn = covDates.length ? Number((await sql`select count(*)::int n from ops_saturday_coverage where saturday = any(${covDates}::date[])`)[0].n) : 0;
  const counts = { swaps: { blob: swaps.length, table: swapsIn }, ticks: { blob: ticks.length, table: ticksIn }, coverage: { blob: covDates.length, table: covIn } };
  const spot: Record<string, any> = {};
  if (swaps.length) { const s = swaps[swaps.length - 1]; const r = (await sql`select * from ops_swap where id = ${s.id}`)[0]; const back = r ? rowToSwap(r) : null;
    spot.swap = { id: s.id, ok: !!back && back.status === s.status && back.to.ext === s.to.ext && back.covers.from === s.covers.from && back.covers.to === s.covers.to && (back.decided_at ?? null) === (s.decided_at ?? null) }; }
  if (ticks.length) { const t = ticks[Math.floor(ticks.length / 2)]; const r = (await sql`select ticked_at from ops_checklist_tick where saturday = ${t.d}::date and tech_ext = ${t.ext} and item = ${t.item}`)[0];
    spot.tick = { key: `${t.d}/${t.ext}/${t.item}`, ok: !!r && isoOf(r.ticked_at) === new Date(t.at).toISOString() }; }
  if (covDates.length) { const d = covDates.sort()[covDates.length - 1]; const r = (await sql`select * from ops_saturday_coverage where saturday = ${d}::date`)[0];
    spot.coverage = { saturday: d, ok: !!r && String(r.name) === cov[d].name && String(r.source) === cov[d].source && String(r.ext) === cov[d].ext }; }
  const ok = counts.swaps.blob === counts.swaps.table && counts.ticks.blob === counts.ticks.table && counts.coverage.blob === counts.coverage.table && Object.values(spot).every((x: any) => x.ok);
  await audit(sql, "ops_rotation_storage_migrate", actor, { counts, spot, ok, keys: st.blobs });
  if (!ok) return { ok: false, counts, spot, note: "a count or the spot-check did not match — the blobs were kept and remain the store; nothing was dropped" };
  await upsertKey(sql, STORAGE_KEY, { migrated_at: now.iso, by: actor, counts }, "ops_rotation_storage_cutover", actor, { counts, spot });
  await sql`delete from automation_config where key in (${SWAPS_KEY}, ${CHK_KEY}, ${COVERAGE_KEY})`;
  await audit(sql, "ops_rotation_storage_drop_blobs", actor, { keys: [SWAPS_KEY, CHK_KEY, COVERAGE_KEY], counts });
  return { ok: true, counts, spot, migrated_at: now.iso, note: "counts and spot-check matched; the tables are the store and the blobs were dropped" };
}
// PSA agent ids for the Saturday pool (by email, case-folded), so history can look up what each
// holder did that day. Scrubbed databases have no matching emails: the row then says "unmatched".
async function readAgentsByEmail(sql: any, emails: string[]): Promise<Map<string, number>> {
  const m = new Map<string, number>();
  const list = emails.map(e => e.toLowerCase()).filter(Boolean);
  if (!list.length) return m;
  try {
    const rows = await sql`select agent_id::int agent_id, lower(email) email from psa_agent where deleted_at is null and lower(email) = any(${list}::text[]) order by is_disabled, agent_id`;
    for (const r of rows) if (!m.has(r.email)) m.set(r.email, Number(r.agent_id));
  } catch (_) {}
  return m;
}
async function readActivity(sql: any, agentIds: number[], sinceYmd: string): Promise<Activity[]> {
  if (!agentIds.length) return [];
  // Two branches, each on its own index — (who_agentid, datetime) and the partial (actionby_agent_id, datetime)
  // where who_agentid is empty — instead of one CASE expression that forced a sequential scan of the table
  // (measured 2026-09-11: 209 ms of a 273 ms job). Same rows, same aggregation.
  try {
    const rows = await sql`select x.date, x.agent_id, count(*)::int actions, count(distinct x.psa_ticket_id)::int tickets, min(x.datetime) first_at, max(x.datetime) last_at
      from (
        select ((a.datetime at time zone ${TZ})::date)::text date, a.who_agentid::int agent_id, a.psa_ticket_id, a.datetime
          from psa_action a where a.who_agentid = any(${agentIds}::int[]) and a.datetime >= ${sinceYmd + "T00:00:00Z"}::timestamptz - interval '1 day'
        union all
        select ((a.datetime at time zone ${TZ})::date)::text date, a.actionby_agent_id::int agent_id, a.psa_ticket_id, a.datetime
          from psa_action a where coalesce(a.who_agentid, 0) <= 0 and a.actionby_agent_id = any(${agentIds}::int[]) and a.datetime >= ${sinceYmd + "T00:00:00Z"}::timestamptz - interval '1 day'
      ) x
      where extract(isodow from (x.datetime at time zone ${TZ})) = 6
      group by 1, 2`;
    return rows.map((r: any) => ({ date: String(r.date), agent_id: Number(r.agent_id), actions: Number(r.actions), tickets: Number(r.tickets),
      first_at: r.first_at ? new Date(r.first_at).toISOString() : null, last_at: r.last_at ? new Date(r.last_at).toISOString() : null }));
  } catch (_) { return []; }
}

// ---- assembly (pure, so the local render and tests can drive it with a fixed clock) ----------------
export type WriterRun = { id: number; ts: string; action: string; actor: string; trigger: string | null; holder: string | null; ok: boolean | null; changes: number | null };
export type WriterStatus = { enabled: boolean; script: string; schedule: string; last: WriterRun | null; recent: WriterRun[] };
export const WRITER_SCRIPT = "f/rmm/oncall_presence_writer";
// The presence writer's single on/off switch, and it lives in WINDMILL, not in this app's roster JSON.
// The dashboard only REPORTS it: arming a job that moves a live phone queue is a Windmill Variables
// action, findable by someone who has never opened this dashboard, and it gates the schedule, Apply now
// and the swap-accept trigger identically. Anything but the exact string "true" is off.
export const WRITER_FLAG_VAR = "f/rmm/oncall_rc_writer_enabled";
// The armed test, pulled out so it is one expression in one place and a test can bind to it directly.
// Exact string "true" only: "yes", "1", "TRUE " with a stray space from a paste, and a missing variable
// are all off. A switch that arms a live phone queue does not get to be generous about what counts as on.
export const flagIsOn = (raw: unknown): boolean => String(raw ?? "").trim().toLowerCase() === "true";
export async function writerEnabled(): Promise<boolean> {
  try { return flagIsOn(await (wmill as any).getVariable(WRITER_FLAG_VAR)); } catch (_) { return false; }
}
export type AssembleExtras = { chk?: ChkStore | null; activity?: Activity[]; agentOf?: (p: Person) => number | null; coverage?: CoverageStore | null; overrides?: Override[]; writer?: WriterRun[]; slim?: boolean; writer_enabled?: boolean };
export function assemble(now: EtNow, rc: RcResult | null, weeks: number, action: string, resolved: ResolvedConfig, swaps: Swap[] = [], viewer: Viewer | null = null, extras: AssembleExtras = {}) {
  const { cfg } = resolved;
  const out: any = { tz: TZ, now: now.iso, today: now.ymd,
    config: { key: CONFIG_KEY, oncall_source: resolved.oncall_source, swing_source: resolved.swing_source, problems: resolved.problems },
    viewer: viewer ?? { email: null, party: null, note: "identity not resolved", ...viewerRoles(null, cfg), ...adminFields(null, { admins: [], note: null }) } };
  // Swap history is the last 90 days by period (the same window the manager view uses for Saturdays).
  const recent = swaps.map(normSwap).filter(s => swapStartMs(s) > now.ms - HISTORY_DAYS * 86400000).map(s => swapView(s, now.ms))
    .sort((a, b) => (a.status === "pending" ? 0 : 1) - (b.status === "pending" ? 0 : 1) || (a.covers.from < b.covers.from ? -1 : a.covers.from > b.covers.from ? 1 : 0));
  const recentOvr = (extras.overrides ?? []).filter(o => periodStartMs(o.kind, o.covers.from) > now.ms - HISTORY_DAYS * 86400000).map(overrideView)
    .sort((a, b) => (a.status === "active" ? 0 : 1) - (b.status === "active" ? 0 : 1) || (a.covers.from < b.covers.from ? -1 : a.covers.from > b.covers.from ? 1 : 0));
  if (action === "all" || action === "details" || action === "oncall") {
    const oncall = buildOncall(now, cfg.oncall, weeks, swaps, extras.overrides ?? []);
    const r: RcResult = rc ?? { configured: false, ok: false, error: "RingCentral was not read", checked_at: null, members: [], account: null, queue: null };
    const exemptPeople = [cfg.oncall.cto, ...cfg.oncall.drift_exempt];
    const drift: Drift = r.ok
      ? assessDrift(oncall.current, oncall.previous, r.members, oncall.cutover_pending, exemptPeople)
      : { state: "unknown", headline: r.configured ? "RingCentral unreachable" : "RingCentral not configured",
          findings: [{ level: "info", text: r.error ?? "RingCentral could not be read." }], active: [], expected_member: null, exempt: [] };
    const cto_in_queue = r.ok ? (r.members.find(m => sameAs(m, cfg.oncall.cto)) ?? null) : null;
    // The drift check is a check on the writer: say what the writer is doing about it.
    const runs = extras.writer ?? [];
    const writer: WriterStatus = { enabled: extras.writer_enabled === true, script: WRITER_SCRIPT, schedule: "daily 00:05 ET, and after an accepted on-call swap or a reassignment that touches today", last: runs[0] ?? null, recent: runs.slice(0, 10) };
    if (r.ok && drift.state !== "ok") drift.findings.push({ level: "info", text: writer.enabled
      ? `The presence writer is enabled${writer.last ? ` — last ${writer.last.action.replace("rc_presence_", "")} ${writer.last.ts} for ${writer.last.holder ?? "?"}` : " — it has not written yet"}; a rotation admin can run it now from this pod (Apply now).`
      : `The presence writer is off. Turn it on in Windmill: Variables → ${WRITER_FLAG_VAR} → "true". Until then the cutover stays manual and every run here is a dry run.` });
    out.oncall = { ...oncall, roster_source: resolved.oncall_source, ringcentral: { ...r, members: r.members.map(m => ({ ...m, rotation: membershipOf(m, cfg.oncall) })) }, drift, cto_in_queue, writer, swaps: recent.filter(s => s.kind === "oncall"), overrides: recentOvr.filter(o => o.kind === "oncall") };
  }
  if (action === "all" || action === "details" || action === "swing") {
    const swing = buildSwing(now, cfg.swing, weeks, swaps, extras.overrides ?? []);
    const total = SWING.checklist.length;
    // Every Saturday row carries its checklist record (everyone sees it); can_tick is true only for
    // the effective holder while the window is open — the backend re-checks the same rule on chk_tick.
    const saturdays = swing.saturdays.map(s => {
      const w = chkWindow(s.date, now.ms);
      const holder: Person = { name: s.name, ext: s.ext, email: s.email ?? null };
      return { ...s, checklist: { ...chkSummary(chkRecord(extras.chk, s.date, s.ext), total, s.date), window: w, can_tick: !!viewer?.party && samePerson(holder, viewer.party) && w === "open" } };
    });
    const history = buildHistory(now, cfg.swing, swaps, extras.chk ?? null, extras.activity ?? [], extras.agentOf ?? (() => null), HISTORY_DAYS, extras.coverage ?? null);
    out.swing = { ...swing, saturdays, history, history_flagged: history.filter(h => h.flag === "no_evidence").length,
      history_omitted: historyOmitted(now, cfg.swing, extras.coverage ?? null, HISTORY_DAYS),
      roster_source: resolved.swing_source, swaps: recent.filter(s => s.kind === "swing"), overrides: recentOvr.filter(o => o.kind === "swing") };
  }
  // The poll (`all`) carries what the pods render and counts for the footers; the drawer asks for `details`.
  // What is dropped: queue members (the drift verdict stays), decided swaps, reassignment lists, past Saturdays
  // and the writer's history — each replaced by a count. Measured: 24 KB → a few KB stored per poll per tab.
  if (extras.slim) {
    if (out.oncall) { const rr = out.oncall.ringcentral; out.oncall = { ...out.oncall, ringcentral: { ...rr, count: rr.members.length, leftovers: rr.members.filter((m: any) => m.rotation === "none").length, members: [] },
      swaps_count: out.oncall.swaps.length, swaps: out.oncall.swaps.filter((x: any) => x.status === "pending"), overrides_count: out.oncall.overrides.length, overrides: [], writer: { ...out.oncall.writer, recent: [] }, slim: true }; }
    if (out.swing) out.swing = { ...out.swing, history_count: out.swing.history.length, history: [], swaps_count: out.swing.swaps.length, swaps: out.swing.swaps.filter((x: any) => x.status === "pending"), overrides_count: out.swing.overrides.length, overrides: [], slim: true };
  }
  if (!out.oncall && !out.swing) throw new Error(`unknown action '${action}' (all | details | oncall | swing | config | set | reset | people | preview | swap_request | swap_accept | swap_decline | swap_cancel | chk_tick | override_set | override_cancel | storage_migrate | rc_apply | rc_dry_run | rc_restore)`);
  return out;
}

// The swap state machine over a store. Pure apart from the clock: the local render drives it with an
// in-memory list and the same identity rules, so what the browser tests is what the worker runs.
export function applySwapAction(action: string, args: { id?: string; kind?: Kind; period?: string; covers_from?: string | null; covers_to?: string | null; exchange?: string | null; counterparty_ext?: string; note?: string; reason?: string | null },
  identity: Party | null, cfg: RotationConfig, swaps0: Swap[], now: EtNow, overrides: Override[] = []): { swaps: Swap[]; swap: Swap } {
  const swaps = swaps0.map(normSwap);
  if (!identity) throw new Error("Your identity could not be established on this run (no end-user email), so nothing was changed.");
  if (action === "swap_request") {
    const kind: Kind = args.kind === "swing" ? "swing" : "oncall";
    const sec = kind === "oncall" ? cfg.oncall : cfg.swing;
    const counterparty = sec.pool.find(p => p.ext === String(args.counterparty_ext ?? ""));
    if (!counterparty) throw new Error("pick a counterparty from the rotation");
    const baseFor = (day: string) => pickRoster(sec.pool, sec.anchor, kind === "oncall" ? mondayOf(day) : day);
    const week_start = String(args.period ?? "");
    // `period` is the week (Monday) or the Saturday; covers_from/covers_to narrow an on-call week to a
    // day or a run of days. Nothing given = the whole period, as before.
    const covers: DayRange = args.covers_from && args.covers_to ? { from: String(args.covers_from), to: String(args.covers_to) } : wholePeriod(kind, week_start);
    const exchange = kind === "oncall" && args.exchange ? { week_start: String(args.exchange), covers: wholeWeek(String(args.exchange)) } : null;
    validateRequest({ kind, week_start, covers, exchange, requester: identity, counterparty, pool: sec.pool, swaps, nowMs: now.ms, baseFor, overrides });
    const me = sec.pool.find(p => samePerson(p, identity))!;
    // Unique even when two requests land in the same millisecond, or when days are re-requested after an
    // earlier request was decided: the store length is part of the id.
    let id = `${kind}-${covers.from}-${now.ms.toString(36)}-${swaps.length.toString(36)}`;
    while (swaps.some(s => s.id === id)) id += "x";
    const swap: Swap = { id, kind, week_start, covers, exchange,
      from: partyOf(me, identity), to: partyOf(counterparty), note: String(args.note ?? "").slice(0, 500),
      status: "pending", requested_at: now.iso, decided_at: null, decided_by: null, decided_reason: null };
    return { swaps: [...swaps, swap], swap };
  }
  const idx = swaps.findIndex(s => s.id === args.id);
  if (idx < 0) throw new Error("no such swap request");
  const swap = swaps[idx];
  const decision = action === "swap_accept" ? "accept" : action === "swap_decline" ? "decline" : action === "swap_cancel" ? "cancel" : null;
  if (!decision) throw new Error(`unknown swap action '${action}'`);
  authorizeDecision(swap, identity, decision, cfg, now.ms);
  // DECISION REASONS. Approving and declining a Saturday swap both need a reason: it is stored on the
  // record, shown in the swap list and in history, and goes into the outcome notification. On-call
  // (mutual consent between peers) keeps the reason optional for now — a separate decision.
  const reason = String(args.reason ?? "").trim().slice(0, 500);
  if (swap.kind === "swing" && decision !== "cancel" && !reason) throw new Error(`a reason is required to ${decision === "accept" ? "approve" : "decline"} a Saturday swap`);
  const decided: Swap = { ...swap, status: decision === "accept" ? "accepted" : decision === "decline" ? "declined" : "cancelled",
    decided_at: now.iso, decided_by: identity, decided_reason: decision === "cancel" ? (reason || null) : reason };
  const next = swaps.slice(); next[idx] = decided;
  return { swaps: next, swap: decided };
}

// Actions: all | oncall | swing (the pods) · config (what is in effect, where it came from, the raw row
// and the defaults — no RingCentral call) · set (validate + upsert the document) · reset (delete the
// row; defaults take over) · swap_request / swap_accept / swap_decline / swap_cancel (the override
// layer; identity from the job, never an argument). See docs/ops_rotation_config.md.
export async function main(action: string = "all", weeks: number = 4, config: any = null,
  id: string | null = null, kind: string | null = null, period: string | null = null, exchange: string | null = null,
  counterparty_ext: string | null = null, note: string | null = null, n: number | null = null, on: boolean | null = null, reason: string | null = null,
  covers_from: string | null = null, covers_to: string | null = null) {
  const wk = Math.max(1, Math.min(12, Number(weeks) || 4));
  const now = etNow();
  const db: any = await wmill.getResource("f/rmm/db");
  const sql = pg(db);
  try {
    const st = await storageMode(sql);
    const adm = await readAdmins();
    if (action === "set" || action === "reset") {
      const who = jobActor();
      let cfgNow: RotationConfig; try { cfgNow = resolveConfig(await readKey(sql, CONFIG_KEY)).cfg; } catch (_) { cfgNow = resolveConfig(null).cfg; }
      const admS = await namedAdmins(sql, cfgNow, adm);
      adminGate({ email: who.end_user_email, ...adminFields(who.end_user_email, admS) }, action === "set" ? "Changing the rotation roster" : "Resetting the rotation roster");
      return await writeConfig(sql, st, action, config, now);
    }
    let resolved: ResolvedConfig, raw: any = null;
    try { raw = await readKey(sql, CONFIG_KEY); resolved = resolveConfig(raw); }
    catch (e: any) { resolved = resolveConfig(null); resolved.problems.push(`automation_config could not be read (${String(e?.message || e)}); using defaults`); }
    const admN = await namedAdmins(sql, resolved.cfg, adm);
    if (action === "config") return { key: CONFIG_KEY, raw, ...resolved, defaults: DEFAULTS, storage: st, viewer: await resolveIdentity(sql, resolved.cfg, admN) };
    if (action === "storage_migrate") {
      const viewer = await resolveIdentity(sql, resolved.cfg, admN);
      adminGate(viewer, "Migrating the rotation storage");
      const r = await migrateBlobs(sql, st, now, jobActor().actor);
      return { ...r, storage: await storageMode(sql), viewer };
    }

    // Roster form: who can be added (PSA agent ∩ RingCentral extension), and the weeks a draft would produce.
    if (action === "people") {
      let agents: PsaAgent[] = [];
      try { agents = (await sql`select agent_id::int agent_id, name, lower(email) email from psa_agent where deleted_at is null and coalesce(is_disabled, false) = false order by name`).map((r: any) => ({ agent_id: Number(r.agent_id), name: String(r.name), email: r.email ? String(r.email) : null })); } catch (_) {}
      const rc = await readRcExtensions();
      return { candidates: matchPeople(agents, rc.extensions), ringcentral: { ok: rc.ok, error: rc.error, checked_at: rc.checked_at, count: rc.extensions.length }, psa: { count: agents.length } };
    }
    if (action === "preview") {
      const [swaps, ovrP] = await Promise.all([readSwaps(sql, st, now), readOverrides(sql, st, now)]);
      const after = resolveConfig(config);
      const view = (r: ResolvedConfig) => {
        const oc = buildOncall(now, r.cfg.oncall, wk, swaps, ovrP), sw = buildSwing(now, r.cfg.swing, wk, swaps, ovrP);
        const w = (x: Week) => ({ week_start: x.week_start, week_end: x.week_end, name: x.name, ext: x.ext, swap_id: x.swap_id });
        return { oncall: { cycle_weeks: r.cfg.oncall.pool.length, current: w(oc.current), upcoming: oc.upcoming.map(w) },
          swing: { cycle_weeks: r.cfg.swing.pool.length, saturdays: sw.saturdays.map(x => ({ date: x.date, name: x.name, ext: x.ext, swap_id: x.swap_id })) } };
      };
      return { problems: after.problems, oncall_source: after.oncall_source, swing_source: after.swing_source, before: view(resolved), after: view(after) };
    }

    if (action.startsWith("swap_")) {
      const viewer = await resolveIdentity(sql, resolved.cfg, admN);
      const [swaps, ovr] = await Promise.all([readSwaps(sql, st, now), readOverrides(sql, st, now)]);
      const r = applySwapAction(action, { id: id ?? undefined, kind: (kind as Kind) ?? undefined, period: period ?? undefined, covers_from, covers_to, exchange, counterparty_ext: counterparty_ext ?? undefined, note: note ?? undefined, reason },
        viewer.party, resolved.cfg, swaps, now, ovr);
      const actor = jobActor();
      // The record is written first; the notification comes after and can only annotate it.
      await saveSwap(sql, st, r.swap, r.swaps, action, actor.actor, { ...actor, swap: r.swap });
      let notify: NotifyResult | null = null;
      if (action === "swap_request" || action === "swap_accept" || action === "swap_decline" || action === "swap_cancel") {
        const event = action === "swap_request" ? "request" : action === "swap_cancel" ? "cancel" : "decision";
        notify = await notifyTeams(event, r.swap, resolved.cfg.swing.approver);
        const idx = r.swaps.findIndex(x => x.id === r.swap.id);
        if (idx >= 0) {
          r.swaps[idx] = { ...r.swaps[idx], notify: { ...(r.swaps[idx].notify ?? {}), [event]: notify } };
          r.swap = r.swaps[idx];
          try { await saveSwap(sql, st, r.swap, r.swaps, `${action}_notify`, actor.actor, { ...actor, swap_id: r.swap.id, notify }); } catch (_) {}
        }
      }
      // An accepted on-call swap that touches today rolls the phone now (the writer decides whether anything changes).
      const writer_job = action === "swap_accept" && r.swap.kind === "oncall"
        ? await kickWriter(`swap_accept:${r.swap.id}`, { from: r.swap.covers.from, to: r.swap.exchange ? (r.swap.exchange.covers.to > r.swap.covers.to ? r.swap.exchange.covers.to : r.swap.covers.to) : r.swap.covers.to }, now.ymd) : null;
      return { ok: true, swap: swapView(r.swap, now.ms), viewer, notify, writer_job };
    }
    // The presence writer, on demand (rotation admins): apply now, dry run, or restore a captured snapshot.
    if (action === "rc_apply" || action === "rc_dry_run" || action === "rc_restore") {
      const viewer = await resolveIdentity(sql, resolved.cfg, admN);
      adminGate(viewer, action === "rc_restore" ? "Restoring a RingCentral presence snapshot" : "Running the RingCentral presence writer");
      const trig = `${action === "rc_restore" ? "restore" : action === "rc_apply" ? "manual" : "dry_run"}:${viewer.email}`;
      const args = action === "rc_restore" ? { trigger: trig, mode: "restore", restore_audit_id: Number(id), reason: reason ?? null } : { trigger: trig, mode: action === "rc_apply" ? "apply" : "dry_run" };
      if (action === "rc_restore" && !Number.isFinite(Number(id))) throw new Error("pick a captured snapshot (its audit id) to restore");
      const result = await runWriter(args, true);
      return { ok: true, action, result, viewer, writer: { enabled: await writerEnabled(), recent: await readWriterRuns(sql) } };
    }
    if (action === "override_set" || action === "override_cancel") {
      const viewer = await resolveIdentity(sql, resolved.cfg, admN);
      adminGate(viewer, action === "override_set" ? "Reassigning coverage" : "Cancelling a reassignment");
      if (st.mode !== "table") throw new Error("reassignments need the rotation tables — the storage migration has not run in this workspace yet (Settings → Rotation roster)");
      const [swaps, overrides] = await Promise.all([readSwaps(sql, st, now), readOverrides(sql, st, now)]);
      const actor = jobActor();
      if (action === "override_set") {
        const r = applyOverride({ kind: (kind as Kind) ?? undefined, period: period ?? undefined, covers_from, covers_to, counterparty_ext: counterparty_ext ?? undefined, reason }, viewer.party, resolved.cfg, swaps, overrides, now);
        // The record first, then every superseded request; the cards come after and only annotate.
        await saveOverride(sql, r.override, "override_set", actor.actor, { ...actor, override: r.override, superseded: r.superseded.map(x => x.id) });
        for (const x of r.superseded) await saveSwap(sql, st, x, [], "swap_superseded", actor.actor, { ...actor, swap_id: x.id, override_id: r.override.id });
        const notify = await notifyOverride(r.override, "set");
        r.override.notify = notify;
        try { await saveOverride(sql, r.override, "override_notify", actor.actor, { ...actor, override_id: r.override.id, notify }); } catch (_) {}
        for (const x of r.superseded) {
          const n = await notifySuperseded(x, r.override); x.notify = { ...(x.notify ?? {}), superseded: n };
          try { await saveSwap(sql, st, x, [], "swap_superseded_notify", actor.actor, { ...actor, swap_id: x.id, notify: n }); } catch (_) {}
        }
        const writer_job = r.override.kind === "oncall" ? await kickWriter(`override_set:${r.override.id}`, r.override.covers, now.ymd) : null;
        return { ok: true, override: overrideView(r.override), superseded: r.superseded.map(x => swapView(x, now.ms)), viewer, notify, writer_job };
      }
      const o = overrides.find(x => x.id === id);
      if (!o) throw new Error("no such reassignment");
      const c = cancelOverride(o, viewer.party, reason, now);
      await saveOverride(sql, c, "override_cancel", actor.actor, { ...actor, override_id: c.id, reason: c.cancelled_reason });
      const notify = await notifyOverride(c, "cancel");
      c.notify = { ...(c.notify ?? {}), ...notify };
      try { await saveOverride(sql, c, "override_notify", actor.actor, { ...actor, override_id: c.id, notify }); } catch (_) {}
      const writer_job = c.kind === "oncall" ? await kickWriter(`override_cancel:${c.id}`, c.covers, now.ymd) : null;
      return { ok: true, override: overrideView(c), viewer, notify, writer_job };
    }
    if (action === "chk_tick") {
      const date = String(period ?? "");
      if (!ISO.test(date) || isoDow(date) !== 6) throw new Error("period must be a Saturday as YYYY-MM-DD");
      const [viewer, swaps, store, ovr] = await Promise.all([resolveIdentity(sql, resolved.cfg, admN), readSwaps(sql, st, now), readChk(sql, st, now), readOverrides(sql, st, now)]);
      const holder = coverFor("swing", date, pickRoster(resolved.cfg.swing.pool, resolved.cfg.swing.anchor, date), swaps, now.ms, ovr).holder;
      const total = SWING.checklist.length;
      const next = applyTick(store, date, holder, viewer.party, Number(n), on !== false, now.ms, total);
      const who = jobActor();
      await saveTick(sql, st, date, chkRecord(next, date, holder.ext)!, Number(n), on !== false, now.ms, next, "chk_tick", who.actor, { ...who, saturday: date, n: Number(n), on: on !== false, holder: holder.ext });
      return { ok: true, saturday: date, checklist: { ...chkSummary(chkRecord(next, date, holder.ext), total, date), window: chkWindow(date, now.ms), can_tick: true }, viewer };
    }

    const wantSwing = action === "all" || action === "details" || action === "swing";
    const [rc, viewer, swaps, chk, coverage0, ovr, writerRuns] = await Promise.all([
      action === "all" || action === "details" || action === "oncall" ? readRingCentral() : Promise.resolve(null),
      resolveIdentity(sql, resolved.cfg, admN),
      readSwaps(sql, st, now),
      wantSwing ? readChk(sql, st, now) : Promise.resolve(null),
      wantSwing ? readCoverage(sql, st, now) : Promise.resolve(null),
      readOverrides(sql, st, now),
      action === "all" || action === "details" || action === "oncall" ? readWriterRuns(sql) : Promise.resolve([] as WriterRun[]),
    ]);
    let extras: AssembleExtras = { chk, overrides: ovr, writer: writerRuns, slim: action === "all", writer_enabled: await writerEnabled() };
    if (wantSwing) {
      // History needs each holder's PSA agent id and their Saturday actions over the window — pool
      // members, swap parties, and whoever the coverage records name (they may have left the pool).
      const people: Person[] = [...resolved.cfg.swing.pool, ...swaps.filter(s => s.kind === "swing").flatMap(s => [s.from, s.to]),
        ...Object.values(coverage0?.saturdays ?? {}).map(c => ({ name: c.name, ext: c.ext, email: c.email, rc_id: c.rc_id }))];
      const byEmail = await readAgentsByEmail(sql, people.map(p => p.email ?? "").filter(Boolean) as string[]);
      const agentOf = (p: Person) => (p.email ? byEmail.get(p.email.toLowerCase()) ?? null : null);
      // PSA activity is asked for only where no final cache exists: Saturdays without a record (about to be
      // frozen) and records whose cache is provisional (taken less than a week after the day). Once every row
      // in the window is final, this poll issues no query against psa_action at all.
      const weekAgo = addDays(now.ymd, -7);
      const window = passedSaturdays(now, HISTORY_DAYS);
      const need = window.filter(d => { const c = coverage0?.saturdays?.[d]; return !c || !activityFinal(c, d); });
      const since = need.length ? need.reduce((a, b) => (a < b ? a : b)) : null;
      const ids = [...new Set([...byEmail.values(), ...Object.values(coverage0?.saturdays ?? {}).map(c => c.agent_id).filter((x): x is number => x != null)])];
      const activity = since ? await readActivity(sql, ids, since) : [];
      // Moment (1) of the coverage snapshot: any passed Saturday without a record is frozen now, carrying
      // the day's activity as a provisional cache.
      let coverage = coverage0;
      const fz = freezeCoverage(coverage0, resolved.cfg.swing, swaps, now, chk, agentOf, jobActor().job_id, HISTORY_DAYS, ovr, activity);
      if (fz.frozen.length) {
        coverage = fz.store;
        const who = jobActor();
        try { await saveCoverage(sql, st, coverage, fz.frozen, "swing_coverage_snapshot", who.actor, { ...who, dates: fz.frozen, why: "poll" }); await pruneRetention(sql, st, now, who.actor); } catch (_) {}
      }
      // Finalise: a week after the Saturday the numbers are written to the row for good; later polls skip it.
      if (st.mode === "table" && coverage) for (const d of window) {
        const c = coverage.saturdays[d]; if (!c || d > weekAgo || activityFinal(c, d)) continue;
        const aid = c.agent_id ?? agentOf({ name: c.name, ext: c.ext, email: c.email, rc_id: c.rc_id }); if (aid == null) continue;
        const a = activity.find(x => x.date === d && x.agent_id === aid) ?? { actions: 0, tickets: 0, first_at: null, last_at: null };
        try {
          await sql`update ops_saturday_coverage set actions = ${a.actions}, tickets = ${a.tickets}, first_action = ${a.first_at}::timestamptz, last_action = ${a.last_at}::timestamptz, activity_as_of = now() where saturday = ${d}::date`;
          Object.assign(c, { agent_id: aid, actions: a.actions, tickets: a.tickets, first_action: a.first_at, last_action: a.last_at, activity_as_of: now.iso });
        } catch (_) {}
      }
      // SPREAD, never rebuild. This line used to reconstruct extras from scratch and silently dropped
      // writer_enabled, so every load that wanted swing data — which is every normal dashboard load,
      // action "all" or "details" — reported the presence writer as disabled however the Windmill switch
      // was set. The writer was armed the whole time; only this report of it lied. Add fields here, never
      // a fresh object literal.
      extras = { ...extras, activity, agentOf, coverage };
    }
    return assemble(now, rc, wk, action, resolved, swaps, viewer, extras);
  } finally { try { await sql.end(); } catch (_) {} }
}
