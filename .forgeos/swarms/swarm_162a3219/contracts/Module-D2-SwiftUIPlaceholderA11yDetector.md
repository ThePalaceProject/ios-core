# Module D2 — SwiftUI placeholder a11y / disabled-UI perception detector

**Owner module:** scripts/ + verify-pr.sh
**Risk:** standard
**Est LOC:** ~180

## Background

PP-4421 / HelpSpot 17923: SwiftUI's default placeholder text on labels like "Barcode or Username" reads as disabled UI (gray on white at ~30% opacity). Fix landed as a VStack wrap with an explicit caption Text above each field.

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `scripts/check-swiftui-placeholder-a11y.py` (NEW) | Detects `TextField` / `SecureField` declarations whose ONLY label is a single string literal AND that string is referenced in `Strings.*` localization (i.e., it's user-facing). Without a paired sibling `Text(...)` caption or `.accessibilityLabel(...)` modifier in the surrounding View body. Annotation: `// no-placeholder-a11y: <reason>`. | +110 |
| `scripts/test_check_swiftui_placeholder_a11y.py` (NEW) | 4 tests — violation, clean-with-caption, clean-with-a11yLabel, annotated. | +45 |
| Wiring + hook + wall-failure entry | (analogous to D1) | +25 |

## Predicted survivors

Scan: `grep -rln "TextField\|SecureField" Palace/SignInLogic/ Palace/Settings/`. Predict 2-5 candidate sites (sign-in barcode + PIN, settings, etc.). Triage: small class → wipe in PR.

## Scope (out)

- UIKit `UITextField` — out of scope (different mechanism).
- Reader2 webview text fields — out of scope (inside Readium WebView, not SwiftUI).

## Verification criteria, tests, acceptance — same shape as D1.
