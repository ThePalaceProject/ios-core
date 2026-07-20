---
name: pp-4832-structured-escalation
created: 2026-07-20
author: claude-opus-4-8
---

**ADR refs:** none — ForgeOS governance is off in this environment.

**Ticket:** PP-4832 (offshoot of PP-4825). Stacked on branch
`feat/pp-4825-triage-corpus-generalhelp` (unmerged; re-stack after #1305/PP-4825 land).

**Design source:** Fable review of PP-4825 — `.escalate` carries no entry id, and
`escalate_anyway` / `trust_level` are dead fields (no consumer). The escalation
follow-up machinery already exists (`askEscalationFollowUpOrDraft` asks the entry's
follow-up whenever `matchedEntryId` is non-nil) — the `.escalate` reducer path just
passes `nil`, discarding the recognized entry.

## Claims

- adds field `recognizedEntryId` to `ClassificationResult` (the KB entry the
  classifier recognized as most relevant even when it escalates; nil for a genuine
  no-match)
- changes `LocalClassifier` to set `recognizedEntryId` on the single-low-confidence
  escalate path (a topic WAS recognized, just not confidently enough to suggest)
- changes `LocalClassifier` so an entry with `escalateAnyway == true` returns
  `.escalate` (carrying `recognizedEntryId`) instead of `.suggest` — recognized but
  always routed to a human
- changes `ConversationReducer` `.escalate` handling to pass
  `result.recognizedEntryId` as `matchedEntryId`, so a recognized-but-unsolvable
  topic asks that entry's targeted escalation follow-up before drafting
- changes `ConversationReducer` `.suggest` handling to emit a hedging preamble for
  entries whose `trustLevel` is `.signal` / `.context` (looked up via the reducer's
  knowledgeBase), leaving `.authoritative` entries spoken directly
- adds tests covering: recognizedEntryId on low-confidence escalate; escalate_anyway
  forces escalate-with-recognition; reducer asks the recognized follow-up on escalate;
  reducer hedges a signal entry and not an authoritative one

## Anti-claims

- does NOT change the redaction / `ContextRedactor` surface
- does NOT change how `.suggest` (confident match) or `.disambiguate` route
- does NOT alter the AI-fallback path or its enablement
- does NOT touch the classifier's scoring, distinct-region, normalization, or
  version-gate logic (PP-4825's surface stays fixed)
- does NOT touch sign-in, borrow, download, DRM, or audiobook production code
- does NOT modify the bundled catalog content (no entry sets escalate_anyway yet;
  the mechanism is exercised with synthetic test entries)

## Files in scope

- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/ClassificationResult.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/LocalClassifier.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Reducer/ConversationReducer.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/LocalClassifierTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/StructuredEscalationTests.swift
