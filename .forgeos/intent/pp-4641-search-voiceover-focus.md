---
name: pp-4641-search-voiceover-focus
created: 2026-06-30
author: claude-opus-4-8
---

# Intent: PP-4641 — keep VoiceOver focus on the search field after Search

## Problem
With VoiceOver on, activating the catalog Search keyboard button moves VoiceOver
focus into the results list. It should remain on the search field (WCAG 3.2.2 On
Input). Originates from PP-3834 (commit b149896c6), which deliberately moved focus
to the results; PP-4641 reverses that intent.

## Claims
- Adds a pure, unit-tested gate `SearchAccessibilityFocusPolicy.shouldHandlePostSearchAccessibility(isLoading:query:isVoiceOverRunning:)`.
- Binds the search `TextField` to `@AccessibilityFocusState` via the existing `.searchField` case.
- On search completion (VoiceOver running, non-empty query, finished loading), re-asserts VoiceOver focus on the search field so it does not drift into the results list.
- Preserves the existing search-results VoiceOver announcement (no regression).
- Deleted the now-orphaned `.accessibilityFocused(..., equals: .resultsArea)` binding and the unused `.resultsArea` case left behind by PP-3834.

## Anti-claims
- Does NOT change any non-VoiceOver behavior; results render identically with VoiceOver off.
- Does NOT change `CatalogSearchViewModel` search/pagination/filtering logic.
- Does NOT touch any auth/borrow/return/download/DRM/audiobook critical path.

## Files in scope
- `Palace/CatalogUI/Views/CatalogSearchView.swift`
- `PalaceTests/Accessibility/SearchAccessibilityTests.swift`
