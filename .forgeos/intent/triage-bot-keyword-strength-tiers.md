---
name: triage-bot-keyword-strength-tiers
created: 2026-08-13
author: claude-opus-5
---

**ADR refs:** none — no prior decision covers triage-bot matcher evidence
weighting. `docs/architecture/` has no triage-bot entry; the classifier's design
rationale lives in source comments (`LocalClassifier.swift`) and in the PP-4825 /
PP-4832 PR history (#1307, #1308). ForgeOS ADR API not queried — governance is OFF
in this environment per `CLAUDE.local.md`.

## Context

QA reported on PP-4865 that the triage bot answers nearly every input with
"I haven't seen exactly that before — let me file a ticket", never surfacing
troubleshooting steps. Measured against the shipped catalog, 17 of 21 realistic
patron phrasings escalate.

The cause is the classifier's evidence model, not catalog size alone. Guided
troubleshooting steps exist **only** on `known_issue` entries, and those entries
require **≥2 distinct match regions** to suggest (`LocalClassifier.swift:120`,
the F-002 precision guard). A patron writes one short sentence naming one
symptom, so nearly every real input lands at exactly 1 region and escalates.

Lowering that floor to 1 is not a fix: measured over the shipped catalog it
recovers 9/11 genuine complaints but newly misroutes 6/7 generic ones — e.g.
"the app crashes when I open it" → the CarPlay SIGABRT workaround, for a patron
who has never opened CarPlay. That is the F-002 defect class returning.

Both numbers are high for the same reason: `symptom_keywords` mixes evidence of
very different strength in one flat list, and the classifier can only count
entries in it, not weigh them. KI-008 lists both `"won't download"` (specific,
decisive) and `"download"` (generic, near-meaningless alone) and treats them as
equal. The ≥2 floor is a blunt proxy for "don't trust weak evidence alone" — it
suppresses weak keywords at the cost of suppressing strong ones too.

The `how_to` lane is the existence proof for the alternative: it already runs at
floor 1 without misrouting, because `CatalogSchemaLintTests` forces its keywords
to be multi-word intent phrases. This change generalizes that discipline to
known-issue entries by making keyword strength explicit rather than implicit.

## Claims

- adds an optional `corroborating_keywords` array to the `KBEntry` schema, decoded in `KBEntry.swift`, defaulting to empty so existing catalogs (and the Android/KMP reader of the same JSON) stay valid
- redefines `symptom_keywords` as STRONG evidence (sufficient alone to suggest) and `corroborating_keywords` as WEAK evidence (raises confidence, never sufficient alone)
- changes `LocalClassifier` to require ≥1 strong match region to suggest, replacing the `known_issue` ≥2-total-region floor
- changes `LocalClassifier` scoring to weight a strong region at 1.0 and a corroborating region at 0.5, still saturating at 3.0
- moves the generic single-word keywords already in the shipped catalog (`stuck`, `crashes`, `crashed`, `hangs`, `spinning`, `spinner`, `blinks`, `download`, `stalled`, `bookshelf`, `boxes`, `placeholder`, `reinstall`) from `symptom_keywords` to `corroborating_keywords`
- adds a lint test asserting no `symptom_keywords` entry is a known generic symptom word, so a future weak keyword cannot silently regain sufficient-alone status
- adds a scored corpus fixture (`Fixtures/MatchCorpus.json`) of real patron phrasings drawn from HelpSpot, PII-stripped, labelled with provenance (`mined` = tickets the catalog was authored from; `held_out` = August 2026 tickets postdating the catalog's 2026-07-20 review; `trap` = generic inputs that must escalate)
- adds `MatchCorpusTests` reporting capture rate and misroute rate per provenance slice, asserting zero misroutes on the trap slice

## Anti-claims

- does NOT enable or change the AI fallback wiring (`TriageBotAIWiring`, `ClaudeFallbackClassifier`, the Firebase flag, or the release-build key gap) — that is a separate, still-open gap
- does NOT add, remove, or reword any KB entry, workaround text, or guided step; only the strength partition of existing keywords changes
- does NOT add new keywords to any entry — growing coverage is deliberately left out so the measured delta is attributable to the evidence model alone
- does NOT change the reducer, the conversation state machine, or any UI; the multi-turn follow-up gap QA also reported is untouched
- does NOT change `distinctMatchRegionCount`, the runner-up/ambiguity guards, the per-entry `confidence_threshold`, the version gate, or the context filters
- does NOT change `how_to` behavior — those entries have no corroborating keywords, so their floor-1 path is bit-identical

## Files in scope

- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/KBEntry.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/LocalClassifier.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Resources/catalog.json
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/CatalogSchemaLintTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/MatchCorpusTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/Fixtures/MatchCorpus.json

## Verification

- `swift test` on the PalaceTriageBot package (macOS) — the whole existing suite, not a filtered subset, since `LocalClassifier` behavior is asserted across several existing test classes
- capture / misroute rates reported per provenance slice before and after, so the trade is stated as a number rather than a claim

## Scope amendment (2026-08-13, during implementation)

The original Claims/Anti-claims describe only the evidence model. The work grew
in response to a QA question and an adversarial architecture review, and the
following are now in scope. Recording them here rather than leaving the intent
describing a smaller change than the diff — the reconciliation gate exists to
catch exactly that drift, and it caught it.

Added beyond the original claims:

- `ConversationReducer` and `KBEscalationFollowUp` ARE modified, contradicting
  the original anti-claim "does NOT change the reducer". Escalation now splits
  ticket SCOPING (on any recognition) from the targeted follow-up QUESTION (only
  on strong evidence, or when a prompt declares `presumes_issue: false`). The
  anti-claim was written before the finding that every catalog prompt presumes
  its own bug, which made weak-evidence questioning actively misleading.
- Matching moved from substring to TOKEN comparison (`TextTokenizer`). Not
  foreseen; forced by the discovery that `stalled` matches inside `reinstalled`,
  a defect the old ≥2 floor had been masking.
- Ranking and the margin guard now read strong evidence first. Prerequisite for
  adding any corroborating keyword: without it a weak-many entry outranks a
  strong-one entry and suppresses the better match.
- Keyword changes the original anti-claims forbade ("does NOT add new keywords",
  "does NOT add/remove/reword any KB entry"). Retracted deliberately: the
  near-miss corpus produced evidence that `never works` and `add a library` were
  misrouting real patrons, and `trying to download` was added to recover recall
  the demotions cost. Each change is justified by a cited ticket, not by feel.
- Nine `how_to` entries gained `escalation_follow_up` prompts and corroborating
  keywords, so an unmatched FAQ question reaches support scoped rather than
  blank. These prompts are NEW PATRON-FACING COPY and have not had product
  sign-off.
- Suggestions resting on a single matched concept are now phrased as a question
  rather than asserted.

Claims from the original document that did NOT hold as written:

- "moves the generic single-word keywords … `stalled` …" — `stalled` was NOT
  moved in the first commit. Caught by review; fixed here.

## Verification amendment

- `keyword_strength.py` (scratch, not committed) implements the measured-strength
  approach. It does NOT work at this corpus size: only 5 of 187 strong keywords
  occur ≥3 times across 318 tickets. Recorded as a negative result rather than
  shipped as a 3%-coverage gate.
