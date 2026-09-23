---
name: pp-4910-mini-player-design-revisions
created: 2026-08-10
author: claude-opus-4-8
---

# Intent: PP-4910 — mini audiobook player design revisions

**Routed:** /rigorous-fix (critical-path audiobook UI, single feature) · required
gates: hygiene, stanza, tdd, review:SoD (architect, qa_test, blast_radius),
validation, verify_before_done. All behind the existing `in_app_playback_nav`
Testing-menu flag — not shipped, not GA.

## Claims (what the diff WILL do)
- Reorder the mini audiobook player bar to the revised Figma layout: close (X)
  at the leading edge, then cover, title/author, and the rewind / play-pause /
  forward transport at the trailing edge.
- Drop the mini-player progress bar.
- Add `MarqueeText`: a single-line view that scrolls its text (continuous
  right-to-left crawl, seamless wrap) only when it overflows its slot, and sits
  static/truncated when it fits or Reduce Motion is on. Its pure `shouldScroll`
  decision is unit-tested with full mutant kill.
- Present a "Stop Playback?" confirmation when the patron taps the mini-player
  close control (No, Cancel / Yes, Stop); the alert takes VoiceOver focus.
- Give the mini bar an elevated material surface + hairline border so it reads
  as a distinct floating card in dark mode.
- Retire the catalog "Continue" section: delete `ContinueRowSection`,
  `ActiveSessionsViewModel`, `RecentlyReadingService`, the scroll-collapse infra,
  and their tests, and unhook the wiring through `CatalogView` / `AppTabHostView`.

## Anti-claims (what it will NOT do)
- Does NOT delete or promote the `in_app_playback_nav` Testing flag, and does NOT
  ship / GA the prototype — that stays a separate, product-signed-off decision.
- Does NOT touch the `continuation_cards_enabled` flag definition (kept in place).
- Does NOT change the full-player controls beyond the mini-player transitions,
  and does NOT do the icon-switch redesign (circular control backgrounds,
  numberless skip glyphs, AVRoutePickerView AirPlay) — tracked separately.
- Does NOT delete `BookOpenTracker`; it is left write-only because its recording
  call sites are critical-path (ReaderService / AudiobookSessionManager).
- No new network, DRM, or persistence-migration surface.

## Files in scope
- Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift (mini bar layout +
  dialog + card surface)
- Palace/Utilities/SwiftUI/MarqueeText.swift (new) + PalaceTests/Utilities/MarqueeTextTests.swift (new)
- Palace/Utilities/Localization/Strings.swift (dialog + close copy)
- Palace/CatalogUI/Views/CatalogContentView.swift, CatalogView.swift,
  Palace/AppInfrastructure/AppTabHostView.swift (unhook Continue wiring)
- Deleted: Palace/CatalogUI/Views/ContinueRowSection.swift,
  Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift,
  Palace/MyBooks/RecentlyReadingService.swift + their PalaceTests
- Palace/AppInfrastructure/AppContainer.swift, Palace/MyBooks/BookOpenTracker.swift
  (doc-comments only, note the now-dormant tracker)

## Verification
- TDD: `MarqueeText.shouldScroll` overflow + Reduce-Motion decision, unit-tested,
  100% mutant kill on the covered logic.
- `verify-pr.sh --quick` full battery green (the only red is the known
  systemic-pollution flakes — AccountsManagerTests / TPPBookRegistryLoadReentrancyTests
  — which pass in isolation and are unrelated to this diff).
- Exercised on-device against a live audiobook session: layout, marquee crawl,
  dark-mode card, and the Stop-Playback dialog; catalog Continue-removal verified
  on the simulator.
