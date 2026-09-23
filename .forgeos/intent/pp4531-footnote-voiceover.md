---
name: pp4531-footnote-voiceover
created: 2026-06-22
author: Maurice Carrier
branch: feature/PP-4531-footnote-voiceover
priority: PP-4531 / Sprint 77 / Epic PP-833 EPUB Accessibility (DAISY reading-420)
---

# Intent: footnote handling with VoiceOver in the iOS reader

## Context

Palace iOS fails DAISY reading-420 ("Footnote Reading"): the Reader2 (Readium 3.x)
reader does not surface EPUB footnote semantics to VoiceOver, so a non-visual
reader has no reliable way to recognize a footnote reference, reach the note, and
return to the reference. EPUBs mark the reference with `epub:type="doc-noteref"`,
the note with `doc-footnote` (or `doc-endnote` / `doc-rearnote`), and the return
link with `doc-backlink`.

Grounded surface:
- Footnote refs/notes are inline `<a>` elements in the spine HTML — NOT in the
  Readium manifest — so they are reached via the rendered WKWebView DOM, not via
  `publication`. (This is why the page-list manifest approach from PP-4529 does
  not apply here.)
- `TPPEPUBViewController` already injects JS on chapter render via
  `epubNavigator.evaluateJavaScript(...)` (the chapter-load focus JS in
  `didChangeLocation`), and in VoiceOver mode sets `navigator.view.isAccessibilityElement = false`
  so VoiceOver traverses the WKWebView DOM directly.

## Claims

- New `TPPReaderFootnoteAccessibility` (pure, Foundation-only): classifies an
  element's `epub:type`/ARIA `role` into `.reference`/`.note`/`.backlink` and
  composes the VoiceOver label (e.g. "Footnote 3", "Footnote", "Back to
  reference"). Unit-testable in isolation (16 tests: role parsing + label
  composition), no UIKit/Readium state.
- `annotationJavaScript()` is a thin DOM mirror of the tested label rule; it sets
  `aria-label` on the inline footnote elements so VoiceOver speaks the role +
  marker. No duplication of the label logic's spec.
- Wired into `TPPEPUBViewController.didChangeLocation` (VoiceOver-only, every
  chapter render), additive and idempotent; does not alter reading position.

## Verification

- Unit: `xcodebuild test -only-testing:PalaceTests/TPPReaderFootnoteAccessibilityTests` — 16/16 pass.
- Runtime (pending): device/host-AX VoiceOver pass on the DAISY "Fundamental
  Accessibility Tests: Non-Visual Reading" (reading-420) fixture — focus a
  reference → announced as a footnote reference; activate → note reachable +
  announced; backlink → returns to the reference.

## Files in scope

- `Palace/Reader2/BusinessLogic/TPPReaderFootnoteAccessibility.swift` (new) — pure role classifier + label composer + annotation JS.
- `Palace/Reader2/UI/TPPEPUBViewController.swift` — `annotateFootnotesForVoiceOver()` + call in `didChangeLocation`.
- `Palace/Utilities/Localization/Strings.swift` — 4 footnote VoiceOver labels.
- `PalaceTests/Reader2/TPPReaderFootnoteAccessibilityTests.swift` (new) — 16 unit tests.
- `Palace.xcodeproj/project.pbxproj` — register the two new files (Palace, Palace-noDRM, PalaceTests).

## Anti-claims

- Does NOT change reading position or move VoiceOver focus — the annotation only
  sets `aria-label`s on existing elements; navigation/return is the EPUB's own
  in-content links.
- Does NOT parse footnotes from the Readium manifest/`publication` (they are not
  there) — detection is DOM-only via injected JS.
- Does NOT change how footnotes are authored/marked up in the EPUB.
- Does NOT add a visible popover/inline-note treatment for sighted users
  (separate story); this is screen-reader behavior only.
- Does NOT claim the runtime VoiceOver behavior is verified — only the pure
  label/role logic is unit-tested; the device/host-AX pass is explicitly pending.
