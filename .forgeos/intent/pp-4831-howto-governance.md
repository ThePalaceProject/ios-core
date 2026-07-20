---
name: pp-4831-howto-governance
created: 2026-07-20
author: claude-opus-4-8
---

**ADR refs:** none — ForgeOS governance is off in this environment.

**Ticket:** PP-4831 (offshoot of PP-4825). Branched off
`feat/pp-4825-triage-corpus-generalhelp` (independent of PP-4832). Re-stack after
#1305 + PP-4825 land.

**Why:** a how_to answer references UI ("go to Settings → Libraries") and has no fix
version to expire against, so it goes stale silently when the UI moves — exactly what
happened with the Palace-icon → Settings library-switch reroute. This adds the
governance the how_to lane needs to stay trustworthy, plus one new FAQ entry.

## Claims

- adds field `uiSurface` to `KBEntry` (the UI screen a how_to answer depends on)
- adds field `reviewedAt` to `KBEntry` (the date the answer was last verified)
- adds `ui_surface` + `reviewed_at` to the three existing how_to entries in
  `catalog.json` (HT-001 renewals, HT-002 return-early, HT-003 switch-library)
- adds a how_to entry `HT-2026-004-notifications` to `catalog.json` (hold-ready +
  due-soon reminders — enable notifications; from HelpSpot 18103)
- adds a benchmark shouldMatch case for HT-004 to `ResponseQualityTests`
- adds `HowToGovernanceTests` — a UI-surface change-log registry + a staleness lint
  that fails any how_to whose `reviewed_at` predates its surface's last-changed date,
  requires every how_to to carry a known `ui_surface` + `reviewed_at`, and proves the
  lint has teeth on a synthetic drifted entry

## Anti-claims

- does NOT change the classifier, scorer, normalization, version gate, or reducer
- does NOT change escalation behavior (that is PP-4832)
- does NOT alter the existing how_to keywords or answer text (only adds anchor/date
  metadata) — except adding the new HT-004 entry
- does NOT apply the ui_surface anchor to known_issue entries (how_to only for v1;
  KI text-drift is a separate concern)
- does NOT touch sign-in, borrow, download, DRM, or audiobook production code

## Files in scope

- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Models/KBEntry.swift
- Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Resources/catalog.json
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/ResponseQualityTests.swift
- Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/HowToGovernanceTests.swift
