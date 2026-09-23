# Architecture review: remedy delivery for the triage bot

Recovered verbatim from the reviewing agent's transcript on 2026-08-14 and
committed so it cannot be lost again. This is the review that produced the
12-step implementation path for PP-4865's remedy ladders. It is preserved as
written, including the objections that were later acted on, because the reasoning
behind a decision is worth more than the decision.

Reviewer role: independent architect (adversarial). Verdict:
sound-with-reservations. Subject: the proposal to decouple remedy delivery from
entry matching.

Implementation status as of the commit that adds this file:

| Step | Subject | State |
|---|---|---|
| 0 | Remedy cost tiers, pullToRefresh + switchLibrary cases | done |
| 1 | generic_flow excluded from classification | done |
| 2 | Unrecognised escalate offers the ladder | done |
| 3 | Cells that must not get the ladder | done |
| 4 | Existing guided-step engine reused | done |
| 5 | Load-time CatalogValidator + suppressions | done; the full 42-cell explicit fixture is NOT built |
| 6 | updateApp version gate | done |
| 7 | Weak-recognition ticket scoping | done |
| 8 | escalateWithTrace category-question fallback | done |
| 9 | ResolutionTrace persistence | done |
| 10 | Corpus non-regression report | not done; corpus was lost and is being re-mined |
| 11 | Catalog ladders and copy | done; the sign-in ladder was rejected at copy review and deleted |

Two of the review's objections turned out to describe live defects rather than
risks: `claimsExhaustedEffort` was computed and never called, and
`escalateWithTrace` never fell back to the category question, so a stepped entry
without its own follow-up filed a ticket with nothing asked.

The current-state description of the resulting system is in
[triage-bot-remedy-delivery.md](./triage-bot-remedy-delivery.md).

---

All three findings are folded in below. I read the full branch (10 commits), the intent file, the classifier/reducer/models/catalog, the corpus splits (204/114 confirmed, sign-in is the largest category in both halves), and the test suites.

# VERDICT: sound-with-reservations

The inversion itself — remedy delivery decoupled from entry matching — is right, and Finding 1 makes it *more* right: elimination over a small safe set is exactly what you do when classification has no signal. But three specifics of the proposal as written are flawed and must change: (1) the safety claim is false — two of the six proposed rungs are destructive in this app; (2) the cost-weighted global order is contradicted by your own data (the signin row); (3) the ladder must not be new machinery or a new state — it should be catalog data executed by the existing guided-step engine. Amended that way, build it.

---

## (A) Objections, ranked

### 1. The safety claim is false. Two rungs are destructive, and one can strand a patron. (attacks Q3)

"A generic remedy is never WRONG advice, only sometimes unhelpful" fails on inspection of this app:

- **signOutIn is destructive.** Signing out of a library in Palace removes that library's downloaded content. A patron who signs out and then *cannot sign back in* (expired card, ILS outage — the 26% staff-only class) has been converted from "app misbehaving, books still readable" to "signed out, books gone, locked out." Offering it to a **signin**-category complaint is the degenerate case: their stated problem is that sign-in doesn't work, and Finding 2 confirms support prescribes it there ~once in 55 tickets. The catalog already hands this advice out as prose with no warning (`KI-2026-001` step 3, `KI-2026-006` step 2, `KI-2026-008` step 3 in `Sources/TriageBotCore/Resources/catalog.json`) — the ladder work should retrofit the cost class onto those too, which the shared-remedy design below gives you for free.
- **reinstall is worse.** Deletes every downloaded book across all libraries, and with the live Adobe activation history (PP-4951 — this very worktree's sibling branch is the activation single-flight fix) re-fulfillment after reinstall is not guaranteed. A patron told to reinstall the night before a flight loses the trip's reading. The reducer's own comment already knows this (`ConversationReducer.swift:144-147`).
- **updateApp can be wrong**, not just unhelpful, when the patron is already on latest — and the bot *cannot know* the latest released version offline. `RemedyDetector` only catches patrons who volunteer "up to date." Mitigation exists and is cheap: the catalog is designed for hot update (`README.md:82-83`), so it can carry a `latest_known_version` field; compare with `context.appVersion` via the existing `SemanticVersion`/`FixVersionGate` machinery. Worst case staleness = one release behind = one wasted rung.
- **reopenTitle mid-audiobook** risks playback position (the #18414 position-loss class); **toggleNetwork** ("switch to cellular") can bill a metered patron for a multi-hundred-MB audiobook.

Consequence for the design: replace the safety *claim* with a safety *mechanism* — every `Remedy` carries a declared cost tier (`free` / `disruptive` / `destructive`), destructive rungs are last-or-never per category, always skippable, and carry a data-loss warning (copy-gated). The claim "categorically different risk profile from entry workarounds" survives only for the `free` tier.

### 2. Cost-ordering is refuted by the data; order and membership must be per-category. (attacks Q4, folds Finding 2 + 3)

The proposal's cost order would lead sign-in patrons with pull-to-refresh → update → reopen → **sign out/in** — and Finding 3 shows updateApp is 0% and signOutIn 2% for signin. The two cheapest rungs are the two least applicable in the largest category. Cost-weighting is the right *tiebreak within* a category's applicable set; it is wrong as the *selection* mechanism.

**Is the per-category table the right shape, or overfitting 204 tickets?** The *shape* is right — 6 categories × 7 remedies = 42 enumerable cells, and per CLAUDE.md's own transition-table rule, an enumerated fixture where every cell is explicitly `allowed(rank)` / `suppressed` / `unknown→default` is exactly how this should ship. The *contents* are only trustworthy at the extremes. Use a pre-registered rule, not judgment per cell: deviate from a conservative global default only where the category has ≥15 resolved tickets AND the remedy is ≥20% (promote to front) or ≤3% (suppress). That yields: audiobook leads updateApp; library leads switchLibrary; download promotes reinstall (with its destructive gate — 26% prescription rate does not waive data loss); signin suppresses updateApp+signOutIn; reader inherits the default (n=4 is unknown, not zero). Middle cells (5–15%) inherit the default order — treating them as measured *would* be overfitting. Check the resulting table against the holdout **once**, as validation, and do not iterate against it — a second look starts spending the seal.

One caveat you must record next to the table: **audiobook-updateApp at 55% is era-bound.** The corpus was mined while 3.2.x's broken fulfillment (`KI-2026-010`, `fixed_in`) was driving audiobook tickets; "update the app" was the prescription because a specific release was broken. That prior decays. This is another argument for the table being catalog *data* revisable at review cadence, for the `latest_known_version` gate (which naturally retires the rung as the fleet updates), and for objection 6 (you cannot re-derive the table without closing the telemetry loop).

### 3. The ladder must not be a new state. It should be catalog data run by the existing guided-step engine. (answers Q1 + Q2)

The proposal is silent on mechanism, and the failure mode from the earlier phase — adding state dimensions faster than review samples them — is live here. The right answer is **zero new `ConversationState.Step` cases**:

Model each per-category flow as a catalog entry with `kind: "generic_flow"`, `symptom_keywords: []`, and `user_facing_steps` whose steps carry `remedy:` tags. Then the *entire* existing guided-flow machinery applies verbatim: already-tried skipping (`ConversationReducer.swift:335-361`), step advance/exhaust (`:417-470`), abandon-with-trace (`:509-536`), outcome-driven responses (`:472-507`), per-step diagnostics. The offer itself reuses `.matched(entryId:)` and the existing KB-card affordances (walk-me-through / file-anyway / dismiss).

**What this does to every existing cell**, stated per the standing rule:

| Cell | Effect |
|---|---|
| `.escalate`, no recognition (`escalate-novel`, `ConversationReducer.swift:197-217`) | **The one changed cell.** Destination becomes "offer generic flow" instead of `transitionToDrafting`; a catalog without a generic flow for the category preserves today's behavior exactly (back-compat cell, tested). |
| `.escalate`, weak recognition | Also offers the flow, but the eventual ticket must stay scoped to the weak-recognized entry. No new state payload needed: `state.lastClassification.recognizedEntryId` already persists — the exhaustion path reads it for tags. This is a wiring requirement with its own test, not a new dimension. |
| `.escalate` via `escalate_anyway` (`LocalClassifier.swift:195-207`) | **Unchanged — deliberately.** These entries encode "no safe self-serve fix exists"; that is the 26% staff-only class codified. Ladder never offered. |
| `.suggest` / `.disambiguate` / how_to | Unchanged; matched entry always overrides — there are no merge semantics between entry steps and the ladder, the entry wins wholesale (answers Q1's "what if they disagree about order": they never co-execute). |
| AI-fallback arms (`aiFallbackResolved`/`Unavailable`) | Same insertion point (they call `transitionToDrafting`); one shared branch. |
| All `guidedStep` cells | Structurally identical; exercised by a second entry population, no code change. |
| `awaitingEscalationFollowUp`, drafting, submitting, sent, error | Untouched; reached after exhaustion exactly as after an entry flow. |

Should entries' steps BE remedy references rather than prose? **No.** Half the shipped steps are entry-specific and better than any generic rung ("check the top-right of your screen for airplane mode"). Keep `KBStep.remedy` as the optional annotation it already is — that annotation is the whole coupling the skip logic and telemetry need.

One classifier change is required to keep this safe: `generic_flow` entries must be excluded from classification candidates so they can never win a suggest or pollute the trap slice (a one-line kind filter, tested — objection to *not* doing it: an empty-keyword entry currently still enters `candidates` and `consideredEntryIds`).

### 4. The remedy concept is fragmenting into three representations, and two ladder rungs can't be skip-detected at all.

`Remedy` exists in the detector, in `KBStep.remedy`, and now in the proposed ladder. If the ladder ships its own remedy list, wording and semantics drift across three surfaces. Unify on the `Remedy` enum as the single vocabulary (the design above does this automatically since rungs are `KBStep`s).

Sharper version of the same objection: the proposed rungs **pull-to-refresh** and **switch/check library** have no `Remedy` case, so `alreadyTriedRemedies` cannot skip them. A patron who writes "I pulled down to refresh and nothing happened" would be told to pull-to-refresh — the exact "bot isn't listening" defect PP-4865 just fixed, reintroduced on the new surface on day one. Adding the enum cases + past-tense phrase lists is a prerequisite step, not polish. (Note for KMP parity: new raw-value cases change the shared JSON vocabulary — Android reader must tolerate unknown remedy strings.)

### 5. The measurement loop the ordering story depends on does not exist. (answers Q5)

"Accurate and consistent" must mean, testably:

- **Consistency** = determinism: identical (text, category, context, catalog) → identical action sequence, including rung order. Already partially pinned by `ResponseDeterminismTests`; extend to ladder flows. This is also the argument against any in-app adaptive reordering — it destroys reproducibility of support conversations.
- **Accuracy for the matcher** = the existing capture/misroute/trap numbers on the sealed slice. Unchanged by this work, and the TDD path must prove that (the classifier diff is one kind filter).
- **Accuracy for the ladder** = per Finding 1, *not* "the right remedy was chosen" — that is unknowable from this corpus. The testable properties are: never offer a rung the patron already tried; never offer a suppressed cell; destructive rungs gated and last; termination within a bounded rung count with escalation always reachable; trace fidelity (the ticket records exactly what was tried, in order).
- **What best-in-class measures that this design cannot:** resolution and re-contact. Intercom/Zendesk close the loop — did the issue end, did the patron come back within 7 days? This design emits per-step resolved events and then **discards the trace**: `ConversationReducer.swift:415` is literally `_ = trace` on the resolved path, and the prompt confirms the `KBStep.diagnostic` telemetry is "collected and unused." Until a `.persistResolutionTrace` effect exists and lands somewhere aggregable, every future claim about rung ordering — including re-deriving Finding 3's table as the 3.2.x era decays — is unfounded. This is the single highest-leverage small change in the plan, and it must precede any "learn from data" ambition. Re-contact linkage (ticket id ↔ later ticket) is genuinely out of reach client-side; say so in the docs rather than implying the telemetry covers it.

The smallest honest learning mechanism (Q4's last part): none in-app. Static per-category order in catalog data; re-rank *manually* at catalog review cadence by Wilson lower bound on per-rung resolution once a rung has ≥50 attempts; pre-register that rule now. No bandits, no online weights — 318 tickets sliced 6 ways cannot support them.

### 6. Patrons who should never enter the ladder, and one wiring gap that would blank their tickets.

- `RemedyDetector.claimsExhaustedEffort` is **computed but never called by the reducer** (verified: its only reference outside the detector is its own unit test, `AlreadyTriedTests.swift:36`). "I've tried everything, nothing works" must bypass the ladder to a scoped ticket, or the bot walks an exhausted patron through rungs it was just told were futile.
- Ladder length must be bounded (≤3 rungs per category flow, enforced by the validator) and the existing abandon escape (`userTappedAbandonGuidedFlow`) must be visible on every rung — the 26% staff-only patrons pay the ladder as pure delay; three cheap rungs is a defensible tax, six is not.
- **Wiring gap:** `escalateWithTrace` consults only `entry.escalationFollowUp` (`ConversationReducer.swift:1030-1051`) — it never falls back to `categoryFollowUp` the way `askEscalationFollowUpOrDraft` does (`:966-972`). A generic-flow entry with no follow-up of its own would exhaust its rungs and file **without asking the category question** — recreating the blank-ticket class this branch just eliminated, on the new path. Fix and test regardless of the ladder; it's a latent gap for any stepped entry without its own follow-up.

### 7. Housekeeping this phase should carry, not create

`confidenceThreshold` is documented in-source as inert (`LocalClassifier.swift:169-184`) — delete it or re-derive it before adding another knob next to it. The `.disambiguate` arm asks a question with no answer path (`userAnsweredFollowUp` is a no-op, `ConversationReducer.swift:732-736`) — out of scope here, but do not route anything new through it.

---

## Responses to the three findings, explicitly

1. **Agreed, and it reshapes the tests.** No component may be, or resemble, a complaint→remedy classifier. Test names below assert ordering/suppression/elimination/termination — none asserts "the right remedy was chosen."
2. **Suppression mechanism: allowlist, not blocklist; data for composition, Core code for invariants.** Each category's flow *is* the allowlist (a remedy absent from a category's `generic_flow` is suppressed by default — a new remedy appears nowhere until a category explicitly includes it). The *evidenced invariants* (signin must not contain signOutIn or updateApp; destructive-never-first; length ≤3; every destructive rung skippable) live in a Core **load-time validator**, not only in test-time lint — because the catalog is designed to be server-supplied later, and a validator only in tests would let a hot-pushed catalog violate every rule ("test the producer, not the helper"). The shipped catalog additionally gets a `CatalogSchemaLintTests` pass, and the full 42-cell table is a committed fixture so adding a remedy or category fails a test until every new cell is explicitly decided.
3. **Table shape right; contents thresholded as in objection 2; audiobook-updateApp flagged era-bound; reader = default; one-shot holdout validation.**

---

## (B) TDD path

Ordered. Every step is pure `swift test` in the package — the reducer takes `KnowledgeBase` by injection (`ConversationReducer.swift:33-43`), so every test runs on a **synthetic fixture catalog** and is not blocked on copy sign-off. No UIKit seams are needed; the only new seam is the catalog validator, itself a pure function. Copy-gated steps are marked and sequenced last.

**Step 0 — vocabulary: `Remedy.costTier` + two new cases.**
- Failing test: `AlreadyTriedTests.testDetectsPullToRefresh_pastTense` — `alreadyTried(in: "I pulled down to refresh and nothing changed")` contains `.pullToRefresh`; sibling for `.switchLibrary` ("I switched to my other library card"). Also `RemedyCostTests.testEveryRemedyDeclaresACostTier` is *not* written (constant-assertion fluff); the tier is exercised by the validator tests in step 5 instead.
- Min change: add `.pullToRefresh`, `.switchLibrary` cases + past-tense phrase lists mined from the authoring half; add `costTier` property (`free`/`disruptive`/`destructive`).
- Guard-proof: delete the `.pullToRefresh` phrase list → test fails. (KMP note: document that the Kotlin reader must tolerate unknown remedy raw values.)

**Step 1 — `generic_flow` entries are invisible to the classifier.**
- Failing test: `LocalClassifierTests.testGenericFlowEntries_neverCompeteForMatches` — synthetic KB where a `generic_flow` entry's keywords are the patron's exact words; assert decision is `.escalate`, `recognizedEntryId == nil`, and the generic id is absent from `consideredEntryIds`.
- Min change: add `KBKind.genericFlow`; filter it out of `candidates` in `LocalClassifier.classify` (`LocalClassifier.swift:28-34`).
- Guard-proof: remove the kind filter → the generic entry wins a suggest → test fails. This is also what keeps the trap slice's zero-misroute guarantee intact.

**Step 2 — the changed cell: unrecognized escalate offers the flow; absent flow preserves today.**
- Failing tests: `GenericLadderTests.testEscalateNovel_withCategoryGenericFlow_offersFlowNotImmediateDraft` — after `userSubmittedDescription` with no-match text, `next.step == .matched(entryId: "GF-…")`, a `.kbMatch` message is appended, and **no** `.ticketPreview` exists; and `testEscalateNovel_withoutGenericFlow_draftsExactlyAsToday` — fixture without a generic flow reproduces the current `awaitingEscalationFollowUp`/drafting outcome byte-for-byte.
- Min change: in the escalate arm (`ConversationReducer.swift:197-217`) and the two AI-fallback arms, branch to the generic entry when the category has one.
- Guard-proof: hard-code `transitionToDrafting` back → first test fails; delete the no-flow fallback → second fails.

**Step 3 — cells that must NOT get the ladder.**
- Failing tests: `GenericLadderTests.testEscalateAnywayEntry_neverOffersLadder` (strong match on an `escalate_anyway` fixture entry → targeted follow-up, no generic offer); `testMatchedEntry_overridesLadderEntirely` (a `.suggest` never routes near the generic flow); `testBlanketTriedEverything_bypassesLadder_ticketTaggedExhaustedEffort` — "I've tried everything, nothing works" → no offer, straight to the category follow-up, draft carries an `exhausted-effort` tag.
- Min change: consult `remedyDetector.claimsExhaustedEffort` at `ConversationReducer.swift:120` (store alongside `alreadyTriedRemedies`), branch in the escalate arm.
- Guard-proof: make the ladder offer unconditional on escalate → first and third tests fail. This step wires the currently-dead `claimsExhaustedEffort` (objection 6).

**Step 4 — machinery reuse proven, not assumed.**
- Test: `GenericLadderTests.testLadderFlow_skipsAlreadyTriedRungs_andAcknowledges` — description states a past reinstall; category flow contains a reinstall rung; assert the flow starts at the first untried rung and the acknowledgement message is present. `testLadderFlow_allRungsAlreadyTried_escalatesWithEmptyTraceAndNoFalseFailureClaim` — reuses the PP-4865 c8c9ee3e8 behavior on the new entry population.
- Min change: none expected (that's the point of the design). If these pass first-run, prove they bite by mutation: comment out the `intersection` at `ConversationReducer.swift:335` → both fail. If they *don't* bite, the design claim "zero new machinery" was wrong and the step catches it.

**Step 5 — the 42-cell table + load-time validator (the suppression mechanism, Finding 2/3).**
- Failing tests: `CatalogValidationTests.testSigninFlowContainingSignOutIn_isRejectedAtLoad`; `testDestructiveRungBeforeNondestructive_isRejected`; `testFlowLongerThanThreeRungs_isRejected`; `testDestructiveRungWithoutSkippableResponse_isRejected`; and `RemedyCategoryTableTests.testEveryCategoryRemedyCellIsExplicitlyDecided` — loads the committed 42-cell fixture (`Fixtures/RemedyCategoryTable.json`, cells = `allowed(rank)` / `suppressed(evidence:)` / `default`), asserts the fixture is total over `KBCategory.allCases × Remedy.allCases` and that every shipped generic flow is consistent with it. Adding a remedy or category makes the totality assertion fail until each new cell is decided.
- Min change: `CatalogValidator` (pure func) invoked from `KnowledgeBase.init`/catalog load — **not** only from tests, per objection re: future server catalogs; validator failure falls back to last-known-good/bundled catalog.
- Guard-proof: hand the validator a signin flow containing `signOutIn` → must reject; disable the load-time call (leaving only lint) → a runtime-load test with a violating in-memory catalog fails.

**Step 6 — updateApp version gate.**
- Failing tests: `GenericLadderTests.testUpdateAppRung_skippedWhenAppVersionAtOrPastLatestKnown`; `…offeredWhenBehindLatestKnown`; `…offeredWhenVersionUnknown` (conservative: unknown → offer; a wasted rung beats a suppressed fix).
- Min change: optional `latest_known_version` on `KBCatalog`; skip predicate reusing `SemanticVersion` comparison, applied in `nextUntriedStepIndex` alongside the already-tried skip.
- Guard-proof: flip the comparison → the behind-version test fails.

**Step 7 — weak-recognition scoping survives the ladder.**
- Failing test: `GenericLadderTests.testWeakRecognition_ladderExhausted_ticketStillScopedToRecognizedEntry` — weak-only match → ladder offered → all rungs fail → assert draft tags/`matchedEntryId` reference the weak-recognized entry (read from `state.lastClassification`), not the generic flow id, and the trace still shows the generic rungs tried.
- Min change: exhaustion path reads `lastClassification?.recognizedEntryId` when the flowing entry is `generic_flow`.
- Guard-proof: tag with the generic id instead → fails.

**Step 8 — escalateWithTrace category-follow-up fallback (pre-existing gap, objection 6).**
- Failing test *against current code*: `EscalationFollowUpTests.testGuidedFlowExhausted_entryWithoutOwnFollowUp_asksCategoryQuestion` — fixture entry with steps but no `escalationFollowUp`, catalog with a category follow-up; walk to exhaustion; assert `.awaitingEscalationFollowUp` with the category prompt. Fails today at `ConversationReducer.swift:1030-1051`.
- Min change: route `escalateWithTrace` through the same fallback as `askEscalationFollowUpOrDraft:966-972`.
- Guard-proof: revert to entry-only lookup → fails. Without this, ladder-exhausted tickets are blank — the regression this branch exists to prevent.

**Step 9 — stop discarding the resolution trace.**
- Failing test: `TelemetryContractTests.testResolvedGuidedFlow_emitsPersistResolutionTraceEffect` — assert a `.persistResolutionTrace(trace)` effect on the resolved path (`ConversationReducer.swift:385-415`), and on exhausted + abandoned paths, with outcome and per-step diagnostics intact.
- Min change: new `ConversationEffect` case replacing `_ = trace` at `:415`; `TriageBotIOS` host appends to a local log (existing persistence seam pattern, `PendingDraftStore`).
- Guard-proof: delete the effect append → fails. **This step is what makes any future data-driven reordering honest; it must land in this phase even though nothing reads the log yet — pre-register the reorder rule (≥50 attempts/rung, Wilson lower bound, manual at catalog review) in the entry's doc comment now.**

**Step 10 — corpus-level non-regression.**
- Tests: extend `MatchCorpusTests` reporting with an `offered_ladder` column for blind-escalated cases (reported, like held-out capture — not gated, same rationale as `MatchCorpusTests.swift:201-214`); assert `testLadder_neverPreemptsACapturableCase` — every previously-captured corpus case still reaches its entry. Existing trap/near-miss zero-misroute assertions and the mined ratchet (≥7) must pass untouched — proving the classifier diff was only the kind filter.
- Guard-proof: make the offer branch fire on `.suggest` → preemption test fails.

**Step 11 — copy + shipped catalog (GATED: product sign-off; last, behind a flag).**
- Author the per-category `generic_flow` entries in `catalog.json` per the thresholded Finding-3 table (audiobook: updateApp→reopenTitle→…; library: switchLibrary→…; signin: pullToRefresh/restart-tier only, **no** signOutIn/updateApp; reader: global default; destructive rungs last with warning copy), plus the offer-card copy and destructive-rung warnings. Gate behind a remote-config flag defaulting off (`triage_bot_generic_ladder_enabled`), same pattern as the existing flags (`README.md:19-37`). Batch into the same product-sign-off review as the nine `how_to` escalation prompts the intent file records as still unsigned (`.forgeos/intent/triage-bot-keyword-strength-tiers.md:104-107`) — that debt predates this phase; don't add to the pile twice.
- Everything in steps 0–10 ships green with fixture catalogs regardless of when sign-off lands.

### Do NOT build

- Any complaint→remedy classifier or per-complaint remedy ranking (Finding 1: four independent methods found no signal).
- In-app adaptive/bandit reordering of rungs (overfits 204 tickets; breaks determinism, which is the "consistency" half of the bar).
- A new `ConversationState.Step` case, a parallel step-walker, or merge semantics between entry steps and ladder rungs (entry wins wholesale).
- A blocklist-style suppression rule engine (the per-category allowlist plus the load-time validator covers it with less surface).
- restartDevice/otherDevice rungs just because the enum has them — no category earns them under the ≥20% promote rule; `otherDevice` isn't even a fix, it's a diagnostic, and belongs (if anywhere) in escalation follow-ups.
- New matcher/keyword coverage work inside this phase — it is orthogonal, and coupling it would make the ladder's measured delta unattributable (the same discipline the intent file applied to the strength-tier change).

The 42-cell table fixture, the load-time validator, and the trace-persistence effect are the three pieces I would refuse to let ship without — they are respectively the enumerated-cells answer, the producer-side guard, and the only path to ever replacing today's priors with measured ones.
