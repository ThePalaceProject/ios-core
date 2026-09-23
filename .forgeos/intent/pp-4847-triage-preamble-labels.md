---
name: pp-4847-triage-preamble-labels
created: 2026-07-21
author: claude-opus-4-8
---

**ADR refs:** none recorded for the triage-bot area.

## Context

Two cosmetic triage-bot defects from a regression sim-drive (PP-4847):
1. **Doubled preamble.** The reducer always prepends "Before I file this — " to
   the escalation follow-up question, but 3 of 7 corpus prompts carry their OWN
   preamble ("Before I send this to support —", "Quick question before I file
   this —", "Before I escalate —"), so the patron sees two.
2. **Category label mismatch.** The ticket-preview "Category" field renders
   `draft.category.rawValue.capitalized` — so `signin` → "Signin" (no space) and
   `reader` → "Reader", neither matching the chip the patron tapped ("Sign in",
   "Reading").

## Claims

- adds public computed property `displayName` to `KBCategory` (patron-facing
  label matching the category-chip wording)
- migrates `TicketPreviewCard` category row from `rawValue.capitalized` to
  `category.displayName`
- migrates `CategoryChipsView` chip labels to `category.displayName` (single
  source of truth so chip and preview can never drift again)
- removes the self-preamble from the 3 corpus `escalationFollowUp.prompt`s in
  catalog.json so the reducer owns the single canonical preamble

## Anti-claims

- does NOT change the reducer's preamble wording or the escalation flow
- does NOT change any category `rawValue` (JSON/telemetry keys unchanged)
- does NOT touch redaction, send-consent, or ticket-submission logic
- does NOT touch any auth / DRM / borrow / download path

## Files in scope

- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/KBEntry.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Resources/catalog.json
- Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/TicketPreviewCard.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/CategoryChipsView.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/KBCategoryDisplayNameTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/EscalationPreambleTests.swift
