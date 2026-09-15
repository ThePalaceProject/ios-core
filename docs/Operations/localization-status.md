# Localization status

**Generated — do not hand-edit.** Regenerate with:

```bash
python3 scripts/palace_strings.py report
```

`palace_strings.py check` fails when this document does not describe the current tables, so it cannot drift silently.

## Coverage

| Language | Translated | Of translatable | Missing |
|---|---:|---:|---:|
| de | 604 | 99.8% | 1 |
| es | 604 | 99.8% | 1 |
| fr | 604 | 99.8% | 1 |
| it | 604 | 99.8% | 1 |

## Scope

- **621** localizable keys in the source (app + audiobook toolkit).
- **15** are format-only (`%@ %@`, `%02d:%02d`) with nothing to translate.
- **1** is deliberately untranslated; see `scripts/l10n-untranslated-allowlist.json`, which records a reason for each.
- **605** are therefore in scope.

## Needs confirmation

**30** interpolated SwiftUI keys have a statically inferred format specifier. SwiftUI builds `%lld` for an `Int` and `%lf` for a `Double`, and escapes a literal `%` to `%%`; the inference is a heuristic and the authoritative answer is `xcodebuild -exportLocalizations`.

## Reviewing the translations

This document reports COVERAGE, not quality. Nothing here means a native speaker has read anything. To produce a packet for linguistic review:

```bash
python3 scripts/palace_strings.py packet --file /tmp/review-packet
```

See `docs/Operations/localization-workflow.md` for how strings are added and translated.

<!-- l10n-state: 1f785280808eb61d -->
