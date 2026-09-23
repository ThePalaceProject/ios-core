---
name: send-the-characters-the-patron-typed
created: 2026-08-26
author: claude
type: bugfix
---

# send-the-characters-the-patron-typed

## Claims

- The catalog search field sends the characters the patron typed. A typed `'`
  (U+0027) reaches the search request as U+0027, not U+2019.
- Achieved by wrapping a `UITextField` in a `UIViewRepresentable` scoped to this
  one field, with `smartQuotesType`, `smartDashesType`, `smartInsertDeleteType`
  and `autocorrectionType` all `.no`.
- The wrapped field preserves every affordance the SwiftUI `TextField` provided:
  focus binding, submit label `.search`, the accessibility identifier
  `AccessibilityID.Search.searchField`, accessibility focus, and the
  "Search Catalog" placeholder.
- Those affordances are asserted mechanically through the same
  `AXValue` / `AXPlaceholderValue` channel that settled the bug, not by inspection.

## Anti-claims

- Does NOT use `UITextField.appearance()`. That is global and would also change
  the LCP passphrase field and account forms. Rejected on blast radius.
- Does NOT change how results are fetched, ranked, paged or displayed.
- Does NOT change query construction or URL encoding — both were measured
  faithful for U+0027 and U+2019 and are not implicated.
- Does NOT touch any other text field in the app.
- Does NOT claim a CI test proves the patron-visible outcome. Substitution happens
  in the input system, so no unit test can exercise it. The CI test pins the
  configuration the measurement showed is necessary; the outcome is verified on a
  simulator.

## Files in scope

- `Palace/CatalogUI/Views/CatalogSearchView.swift`
- a new view file for the wrapped field under `Palace/CatalogUI/Views/`
- a new test file under `PalaceTests/`
- `Palace.xcodeproj/project.pbxproj` (via `scripts/pbxproj_add_swift.rb`, both targets)

## Reproduction

Against the real artifact, not inferred. iOS 26.1, simulator 743E6F1D, Palace
built from `origin/develop` 9e7c03dbd. Typed `Alice's` with a straight U+0027
into the catalog search field via HID injection, then read the field byte-exact
two independent ways:

- pasteboard (Cmd-A, Cmd-C, `simctl pbpaste` | hexdump): `41 6c 69 63 65 e2 80 99 73`
- host accessibility `AXTextField.AXValue`: `Alice’s`, codepoint `0x2019`

Both agree the field holds U+2019. The simdrive `observe` mark for the same field
read `Alice's` (straight) at confidence 0.3 — OCR cannot distinguish the glyphs,
so any assertion through that channel passes on this live defect.

## Root cause

iOS applies smart-punctuation substitution in the input system, before the
SwiftUI binding is called. The field is a bare `TextField` with no input-trait
configuration, and SwiftUI exposes no smart-quotes modifier — only
`autocorrectionDisabled`, `disableAutocorrection`, `textInputAutocapitalization`.

The ticket's prescribed fix — disable autocorrection, "matching what the other
five fields already do" — was tested and DISPROVED: with
`.autocorrectionDisabled()` applied the field still held U+2019 across two
samples. `UITextInputTraits.h:244` documents only the default value and asserts
no coupling between `smartQuotesType` and `autocorrectionType`. Reaching
`smartQuotesType` requires UIKit.

The cited precedent is also false: five fields do disable autocorrection, but
`smartQuotesType` appears zero times across `Palace/`, so no field does what the
ticket says they do.

## Verification

**Outcome, byte-exact.** Same simulator (743E6F1D, iOS 26.1), same field, same
typed input, read through host accessibility `AXTextField.AXValue` in every arm
so a difference cannot be the measurement channel:

| build | AXValue | codepoint |
| --- | --- | --- |
| unmodified | `Alice’s` | U+2019 |
| `.autocorrectionDisabled()` (the ticket's prescribed fix) | `Alice’s` | U+2019 |
| **VerbatimTextField (this change)** | **`Alice's`** | **U+0027** |

The unmodified arm was additionally confirmed via a second independent channel —
pasteboard read-back, `41 6c 69 63 65 e2 80 99 73` — so the defect is not an
artefact of either method.

**Affordances, mechanically checked rather than asserted.** Through the same
accessibility channel, on the fixed build: `AXPlaceholderValue='Search Catalog'`,
`AXIdentifier='search.searchField'`, `AXFocused=true` after focus. The focus
bridge is hand-built because a `UIViewRepresentable` does not participate in
SwiftUI's `@FocusState`, so it is the affordance most likely to be silently lost.

**The tests were proven to bite.** Commenting out `field.smartQuotesType = .no`
fails `testMakeUIView_disablesEverySubstitutingInputTrait` with a NAMED assertion
(`UITextSmartQuotesType(rawValue: 0)` vs `(rawValue: 1)`) while the other four
still pass — specific, not blunt, and a real kill rather than a build failure.

**What the tests do NOT prove.** Smart-quote substitution happens inside the iOS
input system, before any binding is called, so no unit test can exercise it. A
test assigning `"Alice's"` to the binding passes identically with or without this
change. The unit tests pin the configuration the measurement showed is necessary;
the patron-visible outcome is established by the table above.

**Not verified by assertion on screen text.** The simdrive `observe` mark for the
same field read `Alice's` (straight) at confidence 0.3 while the bytes held
U+2019 — those marks are OCR and cannot distinguish the glyphs. Any UI test
asserting through that channel passes on this live defect.
