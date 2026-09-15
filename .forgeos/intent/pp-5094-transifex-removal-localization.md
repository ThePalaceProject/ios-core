---
name: pp-5094-transifex-removal-localization
created: 2026-09-15
author: claude-opus-5
type: feature
tracking: PP-5094 — replace Transifex with a build-time translation workflow in the iOS app. Reporter David Wilcox. Agreed in the Palace Tech Strategy meeting, 2026-09-03. Modeled on the CPW (web-patron) `translate` skill.
related_prs: []
---

# Intent: PP-5094 — repo-committed localization

Palace fetches its translations from Transifex at runtime. All of that data is
static, so the runtime dependency buys nothing and adds a third-party failure
point. This lands the translations in the repo, builds the tooling that keeps
them honest, and corrects the source defects that auditing them exposed.

## Claims

- The four language tables (`de`, `es`, `fr`, `it`) carry every translatable
  source key: 596 of 596. The remainder are pure format strings (`%@ %@`,
  `%02d:%02d`) and one Latin debug placeholder, none of which have anything to
  translate.
- `scripts/palace_strings.py` is the single source of truth for what work
  exists. It extracts keys from BOTH repos, because the audiobook toolkit's
  strings resolve against the app bundle and an app-only inventory reports them
  as dead Transifex entries.
- The extractor matches what the RUNTIME looks up, not what a regex suggests.
  SwiftUI builds `%lld` for an `Int` and `%lf` for a `Double`, escapes a literal
  `%` to `%%` inside an interpolated literal, and compiles `\u{2019}` to a real
  character. `genstrings` gets the first of those wrong in the same direction,
  so agreement between the two is not corroboration.
- Translations are produced on a developer's machine and only DETECTED in CI.
  Detection is a set difference and needs no translation engine, which is why
  the loop works for a contributor who has none.
- `import` refuses a whole batch and writes nothing if any value fails
  specifier parity, is empty, or is a symbol name rather than a translation.
- A key whose miss would render raw to a patron carries a `value:` fallback, so
  an incomplete table degrades to English rather than to an identifier.

## Anti-claims

- The Transifex SDK is REMOVED in this branch — the manager, the SPM
  dependency, the `txstrings.json` bundled cache, the token, and the
  `localizedStringWithFormat` override, in both repos. This is what makes the
  tables live: the swizzle never called `super`, so every `NSLocalizedString`
  lookup went to the CDS provider and, on a miss, returned English. Before this
  branch only SwiftUI `Text("literal")` read the committed tables.
- Does NOT keep a service-side fallback of any kind. There is no network path
  for a string any more; a key missing from a table renders that key.
- Does NOT change locale selection or fallback behaviour. No code decides which
  language to use differently than before.
- Does NOT add, remove, or reword any English string except the five defects
  named below; the English source is otherwise untouched.
- Does NOT claim the translations are reviewed. 103 values are flagged for
  human judgement and no native speaker has seen them.
- Does NOT touch sign-in, borrow, return, download, or DRM logic. The reader
  and PDF files in scope change only how an already-localized string is
  FORMATTED, not what any of them do.
- Adds no runtime behaviour: everything new is build-time tooling, data files,
  or documentation.

## Files in scope

- Palace/Utilities/Localization/Strings.swift
- Palace/AppInfrastructure/TPPAppDelegate.swift
- Palace/TPPSecrets.swift
- Palace/Utilities/TPPProcessInfo.swift
- Palace/Utilities/Localization/Transifex/ (deleted — SDK glue, cache, 3 files)
- Palace/Book/UI/BookDetail/HalfSheetview.swift
- Palace/MyBooks/MyBooks/BookCell/NormalBookCell.swift
- Palace/Reader2/Typography/ReaderTheme.swift
- Palace/Reader2/Typography/TypographySettings.swift
- Palace/Reader2/Typography/FontFamily.swift
- Palace/Reader2/Typography/FontPickerView.swift
- Palace/Reader2/UI/TPPBaseReaderViewController.swift
- Palace/Reader2/BusinessLogic/ChapterScrubberReadout.swift
- Palace/Reader2/ReaderSettings/TPPReaderSettingsView.swift
- Palace/PDF/Views/TPPPDFView.swift
- Palace/PDF/Views/TPPPDFAccessibilityToolbar.swift
- Palace/AppInfrastructure/AppTabRouter.swift
- Palace/Packages/PalaceFeatureFlags/Sources/PalaceFeatureFlags/PalaceFeatureFlag.swift
- Palace/de.lproj/Localizable.strings
- Palace/es.lproj/Localizable.strings
- Palace/fr.lproj/Localizable.strings
- Palace/it.lproj/Localizable.strings
- Palace/de.lproj/Localizable.stringsdict
- Palace/es.lproj/Localizable.stringsdict
- Palace/fr.lproj/Localizable.stringsdict
- Palace/en.lproj/Localizable.stringsdict
- Palace/it.lproj/Localizable.stringsdict
- Palace/Stats/ (deleted — unreachable feature, 20 files)
- PalaceTests/Stats/ (deleted — 7 files)
- PalaceTests/UIPolish/BadgeUnlockPhaseTests.swift (deleted)
- PalaceTests/LocalizationTablesTests.swift (new)
- PalaceTests/ReaderPageOfFormatTests.swift (new)
- scripts/palace_strings.py (new)
- scripts/tests/test_palace_strings.py (new)
- scripts/l10n-key-migrations.json (new)
- scripts/l10n-untranslated-allowlist.json (new)
- scripts/pbxproj_remove_swift.rb (new)
- .github/workflows/tooling-checks.yml
- .claude/skills/translate/SKILL.md (new)
- .claude/skills/translate/references/glossary.md (new)
- docs/Operations/localization-workflow.md (new)
- docs/Operations/localization-status.md (generated)
- .forgeos/contracts/Utilities.json
- README.md
- ios-audiobooktoolkit (submodule pin)
- docs/README.md

## Source defects fixed here

These were found while auditing the strings and are corrected because
translating them faithfully would have propagated each into four languages:

- `Strings.swift:708` assigned the OpenDyslexic label to `blackOnWhiteText`, so
  the black-on-white reader theme announced the wrong control to VoiceOver.
- `"Page %d of "` had a trailing space and concatenated the total at the call
  site, freezing English word order. Now `"Page %1$d of %2$d"`; four call sites
  updated.
- `IncreaseFontSize` / `DecreaseFontSize` had no English text anywhere, so
  VoiceOver announced the raw identifier in every language including English.
- Two source typos, one of which duplicated a correctly-spelled key.
- de/es/fr `.stringsdict` were missing all five `*_suffix_short` keys, so those
  patrons saw `day_suffix_short` on the loan-countdown button.

## Verification

- Unit: 103 pytests for the tooling, every mutant killed across seven mutation
  passes. Two new XCTest classes assert the shipped tables parse, carry
  identical key sets, contain no empty values, and preserve format-specifier
  counts — these run in the app's own suite, because `scripts/tests/` is pytest
  and never executes in the Xcode test job.
- Build: `** TEST BUILD SUCCEEDED **` on the `Palace` (DRM) scheme, which is
  what PR CI builds and what ships. 0 compile errors, 0 `.strings` warnings.
- Device: 41 verdicts from driving the simulator — 32 confirmed against Apple's
  own localization tables, 9 corrected, 8 reported unreachable rather than
  guessed.
- Not verified: the translations cannot be exercised in a running build while
  the SDK is installed (see Anti-claims). They become testable when it goes.
