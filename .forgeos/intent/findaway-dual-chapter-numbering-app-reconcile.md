# Intent — Findaway dual chapter-numbering: app reconcile (PR2)

Critical path: `Palace/Audiobooks/`. Pairs with toolkit PR
ThePalaceProject/ios-audiobooktoolkit#184 (the TOC-collapse fix).

## Claims
1. Bumps the `ios-audiobooktoolkit` submodule pointer `28de55a` → `51d291c` (the
   TOC-collapse fix: one chapter per physical track for oversubdivided/dense
   manifests).
2. Makes `AudiobookSessionManager.normalizedChapters(for:)` a **passthrough**
   (`return toc.toc`) — the toolkit now owns TOC collapse, so the app consumes the
   already-collapsed list. Eliminates the second collapse implementation that
   diverged from the toolkit (the Findaway "Dune" dual-numbering bug).
3. Adds `PalaceTests/Audiobook/FindawaySavedVsPlayedTests.swift` + the
   `dune_oversubdivided_manifest.json` fixture: asserts the saved-vs-played
   invariant (a bookmark taken on physical track findaway:1:3 saves to 1:3, not the
   device-log's 1:4, and round-trips back to 1:3).

## Anti-claims
- Does NOT bump the build number (CURRENT_PROJECT_VERSION) — no new TestFlight
  build (release gate active).
- Does NOT change the player/engine, the position-save format, the Manifest
  decoder, or `TrackPosition`/`toAudioBookmark`.
- Does NOT delete `ChapterTOCNormalizer` / `normalizedChaptersCount` — they remain
  as the unit-tested threshold spec (now implemented in the toolkit); the
  production collapse path is the only thing removed from the app.

## Files in scope
- `ios-audiobooktoolkit` (gitlink bump)
- `Palace/Audiobooks/AudiobookSessionManager.swift` (passthrough)
- `PalaceTests/Audiobook/FindawaySavedVsPlayedTests.swift` (new)
- `PalaceTests/dune_oversubdivided_manifest.json` (new fixture)
- `Palace.xcodeproj/project.pbxproj` (PalaceTests target wiring)
