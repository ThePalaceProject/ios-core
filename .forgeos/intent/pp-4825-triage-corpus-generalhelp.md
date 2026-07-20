---
name: pp-4825-triage-corpus-generalhelp
created: 2026-07-20
author: claude-opus-4-8
---

**ADR refs:** none queried — ForgeOS governance is OFF in this environment (swapped to
heka2 per project setup); the ForgeOS ADR ledger is deprecated here and was not consulted.

**Ticket:** PP-4825. Follow-ups filed: PP-4831 (how-to lane governance & growth),
PP-4832 (structured honest-escalation).

**Design source:** Fable design review (2026-07-20). The ticket ("expand the demo corpus")
sits on top of two live matcher bugs and a data contradiction that must be fixed first, or
the corpus/threshold work operates on noise:
1. `LocalClassifier` normalizes with `lowercased()` only — the iOS smart-punctuation
   apostrophe (U+2019) matches none of the ASCII-apostrophe keywords → silent recall
   collapse on the app's own keyboard.
2. `matched` counts overlapping keyword-list entries, so one word ("hangs") matches both
   `"hang"` and `"hangs"` → count 2 → clears the `>=2` F-002 guard → confident suggest off
   a single word.
3. KI-001 has `status: open` AND `fixed_in_version: 3.2.0`; the gate only filters
   `.fixedIn`, so 3.2.0+ patrons see a card saying "shipping a fix in the next release".

## Claims

- adds `TextNormalizer` normalization (folds U+2019/U+2018 apostrophes to `'` and Unicode
  hyphen variants to `-`, plus lowercasing) in `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/`
- migrates `LocalClassifier.classify` to normalize both user text and keywords via
  `TextNormalizer` before substring matching
- changes `LocalClassifier` keyword scoring to count `distinct non-overlapping` matched
  spans (a keyword whose span is contained in a longer matched keyword's span no longer
  double-counts)
- adds field `kind` to `KBEntry` (`known_issue` | `how_to`, defaults `known_issue` for
  backward-compatible decoding)
- changes `KBEntry` to make `status` optional, keyed off `kind` (how_to entries carry an
  answer, not a known-issue status). `userFacingWorkaround` stays required and is reused
  as the how_to answer text (minimal ripple; the ≥25-char quality bar still applies)
- adds per-kind suggest policy to `LocalClassifier`: how_to entries suggest at ≥1 distinct
  region (specific intent phrases), known_issue keeps ≥2
- migrates `LocalClassifier` version-gating to skip `FixVersionGate` for `kind: how_to`
  entries
- adds `how_to` entries to `catalog.json` for renewals, return-early, and switch-library
- adds known-issue entry to `catalog.json` for add-a-second-library (HelpSpot 17930,
  pull-to-refresh)
- removes redundant nested keyword variants + over-broad tokens (`pdf`, `hang`, bridging
  phrases) from `catalog.json` entries (18 pruned); KEEPS bare `download` in KI-008 as a
  load-bearing recall token (distinct-region scoring already neutralizes its precision risk)
- renames the catalog `version` from `v1.1-demo-2026-05-28` to a non-demo `v1.2-2026-07-20`
- changes KI-001 in `catalog.json` to reconcile `status`/`fixed_in_version` (retag so the
  card is not shown-with-stale-message to fixed patrons)
- adds `CatalogSchemaLintTests` asserting status/version consistency + no
  nested-keyword-variants within an entry + no cross-entry keyword collisions
- changes `ResponseQualityTests` to add a current-version (3.3.x) gate sweep, smart-punctuation
  input variants, and how_to recall/precision cases
- changes `ResponseQualityTests` targets: precision 0.90 -> 0.95, rejection 0.85 -> 0.90,
  recall held at 0.75; disambiguate no longer counted as rejection success
- removes the dead `scoreMargin >= 0.1` disjunct from the `LocalClassifier` suggest guard
  (provably unreachable under quantized scores)
- changes HT-001 renewals keywords to multi-word intent phrases (fixes a bare-`renew`
  false positive on "renewed my card" found in the Fable test review)
- adds `ClassifierInternalsTests` (direct distinct-region unit tests + suggest-guard
  decision table + score-scale + cross-kind + malformed-gate; mutation-verified to kill
  8 previously-surviving mutants)
- adds exact known-miss allowlists + per-kind recall AND precision floors (how_to
  precision target 1.0 — a wrong FAQ is worse than escalating) + a confidence<=1
  invariant to `ResponseQualityTests`; adds how_to-multi-word, unique-id, and
  nested-set-allowlist lints to `CatalogSchemaLintTests`

## Anti-claims

- does NOT introduce a second classifier or a second package — same scorer, same
  escalate-by-default
- does NOT implement the how_to staleness lint / reviewed_at governance (deferred to PP-4831)
- does NOT implement `Decision.escalate(entryId:)`, wire `escalate_anyway` / `trust_level`,
  or add an `escalationTarget` field (all deferred to PP-4832 — adding an unread field now
  would just be another dead knob, exactly what Fable flagged)
- does NOT change the redaction / `ContextRedactor` surface
- does NOT change the Mail-composer ticket transport or any UI gateway
- does NOT touch sign-in, borrow, download, DRM, or audiobook production code — this is the
  local triage-bot package only
- does NOT remove the `fixed_in` entries (KI-002/003/005/007); the version gate already
  hides them from current-build patrons and they still serve the pre-fix cohort

## Files in scope

- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/TextNormalizer.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/LocalClassifier.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/AIFallback.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/KBEntry.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/KBMatchCard.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Resources/catalog.json
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/LocalClassifierTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/ResponseQualityTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/CatalogSchemaLintTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/TextNormalizerTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/KBKindTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/ClassifierInternalsTests.swift
