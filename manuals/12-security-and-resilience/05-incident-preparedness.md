# 12.05 — Incident Preparedness

> **Why this matters here:** the incident will happen at a moment you did not
> choose, to a person who did not build the thing that broke, in a market that
> will not wait. Everything that has to be *invented* during those first sixty
> seconds is a minute of a machine committing capital at 128 nanoseconds per
> decision. Preparedness is not a document; it is the set of things that are
> already decided, already tested, and already reachable before anyone needs
> them.

---

## 1. ⚠️ The first action is always to stop trading

Not "assess". Not "check whether it's really a problem". Not "let me just look at
one dashboard".

> **HIT THE KILL SWITCH FIRST. UNDERSTAND SECOND.**

This is the single rule in this tier that must be memorised rather than looked
up. It is also the rule that every competent engineer instinctively resists,
because engineers are trained to diagnose before intervening. In this domain that
training is actively harmful. The arithmetic from
[01-threat-model.md](01-threat-model.md) §4 is why:

| Action | Cost if you were wrong | Cost if you were right and delayed 60 s |
| --- | --- | --- |
| Kill immediately | One session's opportunity cost. Fully reversible | — |
| Diagnose first | — | Up to 60 seconds × line-rate order flow. Irreversible |

The trigger is **unexplained**, not **obviously broken**. If you cannot say in one
sentence why the system is doing what it is doing, that is the condition. A
latency histogram that moved, a reject counter that started climbing, a fill you
did not expect, a position that does not match the drop copy, a symbol quoting
when it should not be — all of these are "kill first".

⚠️ **There is no penalty, social or professional, for an unnecessary kill.** If
your organisation creates one — through teasing, through a post-mortem that asks
"did you need to do that?", through a metric that counts halts — you have built a
culture that will delay the necessary one. Make this explicit, in writing, and
have the people with authority say it out loud regularly.

**What "kill" means precisely here:** new order emission stops within
`KILL_RESP_CYCLES`; **cancels continue to work**; fills continue to be processed
and accounted. `KILLED ≠ SILENT`. Getting flat is the second action, not
something the kill switch prevents. See
[04-resilience-and-failure-isolation.md](04-resilience-and-failure-isolation.md) §4.

---

## 2. Kill authority

| Question | Answer for this project |
| --- | --- |
| Who may hit the kill switch? | **Anyone on the rota, plus any engineer, plus compliance, plus the trading owner** |
| Does it need approval? | **No. Never. From anyone.** |
| Does it need a reason? | Not before. Yes, in writing, afterwards |
| Can it be overridden by someone senior? | No — the latch is in fabric and re-arming is a deliberate two-step sequence with all triggers clear |
| What if the wrong person hits it? | Then trading stopped. That is a functioning safety system, not an incident |

⚠️ **Standing authority must be granted in advance and in writing**, because at
3am the person watching the alert will otherwise spend two minutes deciding
whether they are allowed to act. Two minutes is the whole incident. The sentence
to have on record is roughly: *"Any person on the on-call rota is authorised and
expected to stop trading immediately, without consultation, whenever system
behaviour is unexplained. No approval is required and none may be requested."*

### The 3am path, in order

Ranked by speed and by how many working components each requires. **Every one of
these must be tested and the test recorded.**

| # | Path | Requires | Response time | Test evidence |
| --- | --- | --- | --- | --- |
| 1 | `ctrld` kill command / dashboard button | Host alive, network, login | ms + human | Game day |
| 2 | Direct BAR write to `CONTROL[1]` | Host alive, shell access | ms + human | Game day |
| 3 | **External `ext_kill_n` GPIO** (front panel / BMC) | Card powered. **No host, no network, no login** | CDC + 16-cycle debounce ≈ 100 ns after the human | ⚠️ Must be exercised — `KILL_SRC.ever_mask` bit 5 |
| 4 | Kill the `heartbeat` process | Shell access | ≤ 100 ms (`WATCHDOG_MS`) | Game day |
| 5 | Log out / drop the order-entry session | `sessiond` or network access | Seconds | Game day |
| 6 | Pull the order-entry cross-connect / disable the switch port | Physical or switch access | Seconds to minutes | Rehearsed annually |
| 7 | Venue emergency desk: mass cancel / disable the port | Phone, and the venue answering | Minutes | ⚠️ Confirm the procedure with the venue in advance |
| 8 | Power off the card / host | Physical or remote power | Seconds | ⚠️ Destroys evidence — last resort |

⚠️ **Paths 1 and 2 share a dependency (the host) and therefore count as one
path.** You need at least one working path that shares nothing with the others —
that is path 3's entire reason for existing, and it is the one most likely never
to have been pressed on the production card. Press it, on a scheduled basis, in a
maintenance window, and record the date.

> **Verify:** your venue's emergency contact procedure, what it can actually do
> (cancel all open orders? disable a port? by MPID or by port?), how it
> authenticates you at 3am, and how long it takes. Get this from the venue in
> writing and print it. Do not learn it during the incident.

⚠️ **Path 8 destroys evidence.** Powering off loses every sticky bit, every
counter, and the entire content of the fabric's state. Use it when nothing else
worked, and expect the post-incident review to be substantially harder.

---

## 3. The runbook

A runbook is not documentation. It is an *instrument*, used by a stressed person
at an inconvenient hour, and it is subject to hard constraints:

| Requirement | Why |
| --- | --- |
| **Printed and physically in the cage / on the desk** | The incident may be "the host is unreachable" or "the network is down" |
| **Not stored only on the trading host** | Same reason |
| **Contains phone numbers, not links** | Venue desk, connectivity support, the trading owner, compliance, the on-call engineer |
| **Written for someone who did not build the system** | The author will be on a plane |
| **Imperative sentences, numbered, no prose** | "Write 1 to CONTROL bit 1" — not "the kill switch may be engaged via the control register" |
| **Every command in full, copy-pasteable** | No "the usual command" |
| **Decision points are explicit, with a default** | "If you cannot determine X within 2 minutes: flatten" |
| **Versioned, dated, and owned** | An out-of-date runbook is worse than none, because it is trusted |
| **Reviewed after every incident and every game day** | The only reliable way it stays true |

**Minimum contents:**

1. **STOP** — the kill paths of §2, in order, with the exact command for each.
2. **VERIFY THE STOP** — how to prove order flow ceased: `orders_emitted` frozen,
   `STATUS.kill_active` set, `KILL_SRC` populated.
3. **CONTAIN** — position from all three sources (fabric, host, drop copy);
   enumerate and explicitly cancel resting orders; verify each cancel acked;
   flatten decision with a default.
4. **PRESERVE** — the evidence snapshot (§4), before anything is cleared,
   restarted, or reprogrammed.
5. **ESCALATE** — who to call, in what order, with what to say.
6. **DIAGNOSE** — the standard first reads: sticky bits, gap counters, reject
   reasons, latency histograms, "what changed today".
7. **RECOVER** — rollback procedure, full start-of-day checklist, canary re-entry.
8. **REPORT** — compliance notification, timeline written before anyone goes home.

The detailed, tickable form of steps 1–8 already exists as
[../07-reference/04-checklists.md](../07-reference/04-checklists.md) §10. **The
runbook is that checklist plus the exact commands and phone numbers for your
deployment.** Do not maintain two divergent copies of the ordering — the
checklist is authoritative for the *steps*, the runbook is authoritative for the
*specifics*.

⚠️ **"What changed today?" belongs in the diagnostic section, near the top.** In
practice the answer is a change roughly as often as it is anything else:
bitstream, parameters, symbol table, host software, network, or a venue notice.
The change trail from
[03-access-control-and-governance.md](03-access-control-and-governance.md) §8(b)
is what makes that question answerable in seconds instead of an hour.

---

## 4. Evidence preservation

Evidence in this system is *volatile* — sticky bits clear on reset, histograms
are finite, and the log ring wraps. Snapshot before you touch anything.

```python
#!/usr/bin/env python3
# scripts/incident_snapshot.py — run IMMEDIATELY after the kill, before anything
# is cleared, restarted, or reprogrammed. Read-only. Never clears a sticky bit.
import datetime, json, pathlib, subprocess, sys

ts  = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
out = pathlib.Path(f"/var/incidents/{ts}")
out.mkdir(parents=True, exist_ok=False)

# 1. Identity first — everything else is meaningless without it.
#    BUILD_ID, GIT_SHA, BUILD_TIMESTAMP, MAP_VERSION.
# 2. Full CSR dump (STATUS, KILL_SRC incl. first_kill_src and ever_mask,
#    KILL_COUNT, CFG_ERR, ARM_STATE, PARAM_GEN, all LOG_* counters).
# 3. Entire telemetry window 0x800-0xBFC — every counter, every sticky flag.
# 4. Latency histograms, all buckets.
# 5. Committed parameter checksums (risk + strategy + filter + template).
# 6. Host state: positions, open orders, session state, recent drop copy.
# 7. Ring-buffer packet captures for the incident window, both directions.
# 8. Host logs for all daemons, and the change trail for the last 48 h.

for name, argv in [
    ("csr_dump.json",   ["ctrld", "dump", "--all", "--read-only"]),
    ("telemetry.json",  ["ctrld", "telemetry", "--raw"]),
    ("histograms.json", ["ctrld", "hist", "--all"]),
    ("positions.json",  ["reconciler", "snapshot"]),
]:
    (out / name).write_bytes(subprocess.run(argv, capture_output=True, check=False).stdout)

(out / "meta.json").write_text(json.dumps({
    "snapshot_utc": ts,
    "taken_by":     sys.argv[1] if len(sys.argv) > 1 else "unknown",
    "reason":       sys.argv[2] if len(sys.argv) > 2 else "unspecified",
}, indent=2))
print(f"snapshot: {out}")
```

⚠️ **`first_kill_src` is the field you will want and the one people forget.** In a
cascade, the last kill source is usually a consequence; the first one is the
cause. `KILL_SRC` latches both, and both are lost on reset. Read them before
anything else.

⚠️ **Do not clear sticky bits, reset counters, restart daemons, or reprogram the
card until the snapshot is complete and copied off the host.** The pressure to
"just restart it and see" is enormous and it has destroyed more root-cause
analyses than any other single behaviour. The system is already stopped; there is
no urgency that justifies destroying the record.

---

## 5. Rehearsal — game day

An untested emergency procedure is a hypothesis about human behaviour under
stress, and it is usually wrong.

| Cadence | Exercise |
| --- | --- |
| **Monthly** | One unannounced kill drill in UAT. Measure wall-clock from alert to confirmed stop |
| **Quarterly** | Full game day: 2–3 scenarios end-to-end including evidence capture and a written timeline |
| **Quarterly** | Rollback rehearsal in UAT (also required by [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) §9) |
| **Per release** | Every `kill_src_e` exercised on hardware; `KILL_SRC.ever_mask` fully populated |
| **Annually** | Physical paths: `ext_kill_n` on the production card in a maintenance window; cross-connect pull; venue emergency-desk contact drill |
| **On joining the rota** | Every new person runs a supervised drill before their first solo shift |

**Scenario library** — run each at least once a year:

| # | Scenario | What it actually tests |
| --- | --- | --- |
| 1 | Runaway order loop in UAT | Rate limiter, kill reflex, time-to-stop |
| 2 | Host process killed with `SIGKILL` mid-session | Watchdog bound, resting-order handling |
| 3 | Position mismatch injected into the drop copy | Do people stop, or do they rationalise a "small" difference? |
| 4 | Both MD feeds gapped simultaneously | Per-symbol gap attribution, recovery path |
| 5 | Feed goes silent, links stay up | Staleness detection — the failure people miss |
| 6 | Order-entry TCP reset at peak | Session recovery, cancel-on-disconnect behaviour |
| 7 | ⚠️ Primary responder unreachable | Escalation actually working, not just being documented |
| 8 | Kill switch itself does not respond | Do people move to path 3, 5, 7 — and how fast? |
| 9 | Bad bitstream loaded | Build-ID arm gate refuses; does anyone try to work around it? |
| 10 | Venue-side outage during an open position | Reconciliation before assuming anything |

⚠️ **Scenario 8 is the most valuable and the least run.** The entire safety
architecture assumes the kill switch works. Rehearsing what happens when it does
not is how you discover that path 5 has no documented command and path 7's phone
number is four years old.

**A game day "passes" only if:**

- The stop happened before the diagnosis started.
- The evidence snapshot is complete and was taken before any restart.
- Somebody who did not build the system executed the runbook successfully.
- Every gap found became a ticket with a named owner and a date.

**Measure and trend these**, release over release: alert → human acknowledged;
acknowledged → confirmed stop; stop → position known; stop → flat; total to
recovery. Numbers that get worse are a signal about the team and the tooling, not
just the process.

---

## 6. Post-incident review

Held within a few business days of **any** incident — including near-misses that
cost nothing, which are the cheapest lessons available.

| Principle | Meaning |
| --- | --- |
| **Blameless** | The output is a list of system changes, not a list of people |
| **Reconstructed, not remembered** | Timeline to the second from the audit log, counters, and captures |
| **Root cause is specific** | A line of RTL, a config value, a procedural gap. ⚠️ "Human error" is not a root cause — it is a request for a better system |
| **Contributing factors listed separately** | The root cause is rarely alone |
| **Detection time is a first-class metric** | How long from fault to notice? What would have caught it sooner? |

The five questions that produce almost all the value, asked every time:

1. **Was there a counter for this?** If not, add one. In this project this is the
   most common and most valuable output of a review.
2. **Was there an alert?** If it existed and did not fire, why? If it fired and
   was ignored, why — noise, or no runbook entry?
3. **Was there a test?** Add the failing case to the regression suite and the pcap
   corpus **permanently**, with a comment naming this incident.
4. **Was the blast radius sized correctly?** Were the limits such that the worst
   case was survivable? Should they change — and if so, that is a class-A change
   with full governance, not a quick edit while everyone is upset.
5. **Did the kill switch work, how fast, and was it reachable?** Plus: was the
   rollback available, current, and rehearsed?

⚠️ **Resist the tightening reflex.** After an incident there is enormous pressure
to halve every limit immediately. Sometimes correct — but a limit change made in
the emotional aftermath, outside the normal control, by the people closest to the
event, is exactly the change class that
[03-access-control-and-governance.md](03-access-control-and-governance.md) exists
to slow down. Follow the process. It is not slower than the harm of getting it
wrong twice.

**Outputs, all mandatory:** a written timeline; root cause and contributing
factors; financial impact quantified; action items with **named owners and
dates** (items without both do not exist); manual corrections filed in the same
week if a document in `manuals/` was wrong, misleading, or silent on this; and an
amendment to the runbook and to
[../07-reference/04-checklists.md](../07-reference/04-checklists.md) §10 if the
procedure itself under-performed.

---

## 7. Regulatory and venue notification

⚠️ **This is a compliance decision, not an engineering one.** Engineering's job is
to notify compliance immediately and give them accurate facts; compliance decides
what is reportable, to whom, and by when. Do not make that call at 3am, and do not
let a well-meaning engineer send an explanatory email to the exchange.

| Obligation area | What typically drives it |
| --- | --- |
| Venue notification | Exchange rules on erroneous orders, clearly erroneous trade filings (which are **time-limited**, often measured in minutes), and system-issue notification requirements |
| Regulatory notification | Firm-specific obligations depending on registration status; supervisory and reporting rules |
| Books and records | The incident record itself becomes a retained record |
| Order/trade reporting | Reporting obligations continue during and after the incident |

> **Verify — all of the following, with compliance and counsel, before you need
> them:** the venue's clearly-erroneous execution filing window and procedure;
> your firm's obligations under **SEC Rule 15c3-5** where a control failure is
> involved; whether **Regulation SCI** notification applies to you (17 CFR
> §§ 242.1000–1007 — a proprietary trading firm is generally *not* an SCI entity,
> but confirm); **SEC Rule 613 / CAT** reporting continuity during an outage; and
> record-retention requirements under **SEC Rules 17a-3/17a-4**. Timeframes and
> applicability change; take none of them from this manual.

**The engineering-side rule:** the moment an incident is declared, compliance is
on the notification list *in parallel with* the technical response, not after it.
A ten-minute delay in telling compliance can convert a reportable-and-handled
event into a reportable-and-late one, which is a different category of problem
entirely.

⚠️ **Clearly-erroneous filing windows are short.** If bad fills occurred, somebody
must be gathering the trade details *while* the engineers are diagnosing. That is
a parallel workstream with its own owner, named in the runbook — not step 25.

---

## 8. Re-entry

Getting back on is where a handled incident becomes a second incident.

| Gate | Requirement |
| --- | --- |
| 1 | Root cause identified, **or** an explicit, recorded decision to stay down until it is |
| 2 | Fix applied or rollback executed per the rollback procedure |
| 3 | Evidence snapshot complete and archived off-host |
| 4 | **Full** start-of-day checklist re-run — not a subset ([../07-reference/04-checklists.md](../07-reference/04-checklists.md) §8) |
| 5 | Build ID verified against the expected release |
| 6 | Risk limits re-verified by a deliberately over-limit test order in loopback/UAT, rejected with the expected `risk_reason_e` |
| 7 | Position reconciled and `position_loaded` written from the reconciled value |
| 8 | Two-step arm, with all triggers clear |
| 9 | **Single-symbol canary at minimum size**, supervised |
| 10 | Full universe only after a supervised session at canary scale |

⚠️ **Never re-arm straight into the full symbol universe**, however confident
anyone is. The kill switch's `position_loaded` precondition is structural for
exactly this reason: re-arming with a zeroed position counter while a real
position exists means the position limit will permit a full new position *on top
of the one you already have*. The hardware makes you write a position; the
process must make sure it is the *right* position, from the drop copy, not from
the fabric's own possibly-wrong counter.

---

## 9. RULES FOR THIS PROJECT

1. **Stop first. Always. Every time.** The trigger is *unexplained*, not
   *obviously broken*.
2. **Standing kill authority is granted in writing to every person on the rota**,
   requires no approval, and can be exercised without consulting anyone.
3. **No penalty, ever, for an unnecessary kill.** Say it out loud, repeatedly.
4. **At least two kill paths must share no dependencies**, and the independent one
   (`ext_kill_n`) is physically exercised on a schedule.
5. **The runbook is printed, dated, owned, phone-numbered, and reachable when the
   host and the network are not.**
6. **Snapshot before you touch.** No restart, reset, sticky-bit clear, or
   reprogram until the evidence is captured and copied off-host.
7. **Every `kill_src_e` is exercised on hardware per release.** An empty
   `ever_mask` bit is an untested control.
8. **Compliance is notified in parallel with the technical response**, not after
   it. Engineering never contacts a venue or regulator directly about an incident.
9. **Post-incident review within days, blameless, with named owners and dates**,
   and the failing case added permanently to the regression suite.
10. **Re-entry is via the full start-of-day checklist and a single-symbol canary.**
    Never straight back to the full universe.
11. **Game day quarterly, kill drill monthly, and scenario 8 — "the kill switch
    does not work" — at least annually.**

---

## Further reading

- [04-resilience-and-failure-isolation.md](04-resilience-and-failure-isolation.md) — the automatic responses that fire before a human sees anything
- [03-access-control-and-governance.md](03-access-control-and-governance.md) — kill authority, change trail, and the post-incident tightening reflex
- [02-supply-chain-and-bitstream-integrity.md](02-supply-chain-and-bitstream-integrity.md) — `BUILD_ID` and the manifest during an investigation
- [01-threat-model.md](01-threat-model.md) §4 — why the response bound is what it is
- [../07-reference/04-checklists.md](../07-reference/04-checklists.md) §10, §11 — the authoritative incident and post-incident checklists
- [../06-operations/01-build-and-release.md](../06-operations/01-build-and-release.md) §9 — the rollback procedure the runbook references
- [../06-operations/03-monitoring-and-telemetry.md](../06-operations/03-monitoring-and-telemetry.md) §7 — what pages a human in the first place
- [../06-operations/04-testing-strategy.md](../06-operations/04-testing-strategy.md) §11 — fault injection, the source of game-day scenarios
