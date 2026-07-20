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
- changes `KBEntry` to make `status` and `userFacingWorkaround` optional, keyed off `kind`
  (how_to entries carry an answer, not a workaround/status)
- adds field `escalationTarget` to `KBEntry` (`palace_support` | `library`, default
  `palace_support`)
- migrates `LocalClassifier` version-gating to skip `FixVersionGate` for `kind: how_to`
  entries
- adds `how_to` entries to `catalog.json` for renewals, return-early, and switch-library
- adds known-issue entry to `catalog.json` for add-a-second-library (HelpSpot 17930,
  pull-to-refresh)
- removes over-broad bare keywords (`loading`, `download`, `pdf`, `boxes`, `stuck`, `first time`)
  from existing `catalog.json` entries where they cost precision
- renames the catalog `version` from `v1.1-demo-2026-05-28` to a non-demo `v1.2-2026-07-20`
- changes KI-001 in `catalog.json` to reconcile `status`/`fixed_in_version` (retag so the
  card is not shown-with-stale-message to fixed patrons)
- adds `CatalogSchemaLintTests` asserting status/version consistency + no
  nested-keyword-variants within an entry + no cross-entry keyword collisions
- changes `ResponseQualityTests` to add a current-version (3.3.x) gate sweep, smart-punctuation
  input variants, and how_to recall/precision cases
- changes `ResponseQualityTests` targets: precision 0.90 -> 0.95, rejection 0.85 -> 0.90,
  recall held at 0.75; disambiguate no longer counted as rejection success

## Anti-claims

- does NOT introduce a second classifier or a second package — same scorer, same
  escalate-by-default
- does NOT implement the how_to staleness lint / reviewed_at governance (deferred to PP-4831)
- does NOT implement `Decision.escalate(entryId:)` or wire `escalate_anyway` / `trust_level`
  into behavior (deferred to PP-4832)
- does NOT change the redaction / `ContextRedactor` surface
- does NOT change the Mail-composer ticket transport or any UI gateway
- does NOT touch sign-in, borrow, download, DRM, or audiobook production code — this is the
  local triage-bot package only
- does NOT remove the `fixed_in` entries (KI-002/003/005/007); the version gate already
  hides them from current-build patrons and they still serve the pre-fix cohort

## Files in scope

- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/TextNormalizer.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/LocalClassifier.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/KBEntry.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Resources/catalog.json
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/LocalClassifierTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/ResponseQualityTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/CatalogSchemaLintTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/TextNormalizerTests.swift
