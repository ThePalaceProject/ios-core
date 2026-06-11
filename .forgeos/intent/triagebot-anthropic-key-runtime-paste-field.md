---
name: triagebot-anthropic-key-runtime-paste-field
created: 2026-06-11
author: claude-opus-4-8
tracking: 3.2.0 release hardening — TestFlight enablement for the Triage Bot AI fallback
related_prs: []
---

# Intent: runtime Anthropic key-paste field in Developer Settings

## Problem
The Triage Bot AI fallback reads its Anthropic key from the Keychain
(`AnthropicKeyStore`). The only path into the Keychain today is
`bootstrapFromEnvironmentIfNeeded()`, which reads `ANTHROPIC_API_KEY` from the
Xcode scheme and is `#if DEBUG`-gated. TestFlight is a RELEASE build, so that
bootstrap is a no-op and there is no other way to load a key — the AI fallback
cannot be exercised on TestFlight at all. Baking the key into the binary is not
an option (it ships to every user and is `strings`-extractable).

## Claims
- Adds a Developer Settings → Triage Bot row "Anthropic API Key" that presents a
  secure-text alert to paste a key (`TriageBotKeyAdmin.save`, which trims and
  refuses empty/whitespace) and, when a key is stored, a destructive "Clear Key"
  action (`TriageBotKeyAdmin.clear`). The row's detail text shows "Stored" / "Not
  set" via `TriageBotKeyAdmin.hasStoredKey`.
- `TriageBotKeyAdmin` is a thin, injectable seam over `AnthropicKeyStore`
  (`AnthropicKeyStoring` protocol) so the trim + empty-rejection + status logic
  is unit-tested without touching the real Keychain.
- The field is reachable on TestFlight (engineering sections render under
  `sandboxReceipt`) and on dev/sim, and hidden on production App Store (real
  `receipt` on disk) — so production users never reach it and their Keychain
  stays empty, leaving the AI fallback off. The key lives only in the device
  Keychain, never in source or the binary.

## Anti-claims
- No change to `RemoteFeatureFlags` defaults or the DEBUG-on policy: release
  builds already default the chatbot + audiobook-nav features OFF and Firebase
  remains the rollout control.
- No production code path reads the env var in RELEASE; the manual field is the
  only RELEASE/TestFlight key path and it is gated behind the engineering-tools
  receipt check and the version-label developer-settings unlock.
- The Keychain itself is not exercised in tests (errSecMissingEntitlement in the
  unit host); the injected-store tests pin the admin logic only.

## Files in scope
- `Palace/Support/TriageBotKeyAdmin.swift` (new)
- `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift`
- `PalaceTests/Support/TriageBotKeyAdminTests.swift` (new)
