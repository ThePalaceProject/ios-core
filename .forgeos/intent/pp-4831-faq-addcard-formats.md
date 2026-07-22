---
name: pp-4831-faq-addcard-formats
created: 2026-07-22
author: claude-opus-4-8
---

**ADR refs:** none recorded for the triage-bot area.

## Context

Completes PP-4831's two remaining named FAQ topics (the story's "Done when"
listed holds, formats/Kindle, borrow limits, adding a card; holds + borrow
limits shipped in #1309). Both answers are product-confirmed: adding a card is a
concrete in-app flow; send-to-Kindle is confirmed **not supported** (Palace reads
in-app; no Kindle export).

## Claims

- adds how_to entry `HT-2026-008-add-library-card` (anchored to
  `settings-libraries`, reviewed 2026-07-22)
- adds how_to entry `HT-2026-009-formats-kindle` (anchored to `my-books`,
  reviewed 2026-07-22) stating Palace is not connected to Kindle
- adds shouldMatch benchmark cases for both in ResponseQualityTests

## Anti-claims

- does NOT change the classifier, reducer, or how_to governance schema
- does NOT add a new `ui_surface` (reuses existing `settings-libraries` /
  `my-books` change-log anchors)
- does NOT touch any auth / DRM / borrow / download path

## Files in scope

- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Resources/catalog.json
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/ResponseQualityTests.swift
