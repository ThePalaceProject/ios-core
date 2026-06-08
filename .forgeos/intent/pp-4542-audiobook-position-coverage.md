---
name: PP-4542 audiobook position-validation candidate-selection coverage
created: 2026-06-08
author: claude-opus-4-8
---

## Summary

F-007 (PP-4542): the position-validation / candidate-selection logic added to
`AudiobookSessionManager` by PR #1028 (stale-position-on-reborrow hardening)
shipped with a 0% diff-only mutation kill rate on the changed lines. Add
behavior tests at the production seams that pin the real decisions —
candidate recency ordering, TOC track-key match, the `validationFailure == nil`
filter, `isValidPosition`, and the `isUserAuthenticated` auth-doc-load-failure
branch — with constructed TOC + registry + account fixtures (no live
Audiobook/player graph).

## Claims

- adds test class `PalaceTests/Audiobooks/AudiobookPositionRestoreTests.swift`
  with behavior tests for candidate ordering, TOC track-key match,
  validation-filter drop, isValidPosition, and isUserAuthenticated failure
- extracts a pure `selectMostRecentValidBookmark(from:in:)` seam out of
  `fallbackToMostRecentValidBookmark` so the candidate filter+sort is testable
  against an `AudiobookTableOfContents` without a live `Audiobook`
- changes visibility of `getValidLocalPosition`, `fallbackToMostRecentValidBookmark`,
  `validationFailure(for:in:)`, `isValidPosition`, and `isUserAuthenticated`
  from `private` to `internal` so `@testable` tests reach them
- registers the new test file in `Palace.xcodeproj` (PalaceTests target)

## Anti-claims

- does NOT change any shipping behavior — the extraction is a pure refactor
  (same candidates, same filter, same sort) and the visibility changes are
  test-reachability only
- does NOT change any call site, method signature semantics, or control flow
  on the audiobook open/restore path
- does NOT touch the audiobook toolkit submodule or any DRM/network code

## Files in scope

- Palace/Audiobooks/AudiobookSessionManager.swift
- PalaceTests/Audiobooks/AudiobookPositionRestoreTests.swift (NEW)
- Palace.xcodeproj/project.pbxproj
- .forgeos/intent/pp-4542-audiobook-position-coverage.md (NEW)
