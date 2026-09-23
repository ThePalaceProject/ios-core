# PalaceTriageBot

<!-- audit-verified: entry/test counts recomputed from catalog.json and Tests/ on 2026-07-28; gateway/AI/flag behavior verified against TriageBotFactory.swift, EmailTicketGateway.swift, RemoteFeatureFlags.swift -->

In-app triage and support bot for Palace. Matches patron problem descriptions
against a curated local knowledge base, walks guided troubleshooting steps,
and escalates unresolved issues as structured, redacted support tickets.

**Full as-built architecture, flows, and gap analysis:**
[`docs/architecture/triage-bot-v1-as-built.md`](../../../docs/architecture/triage-bot-v1-as-built.md).
This README is intentionally short and package-focused.

## Why three products

| Product | Contents | Reusability |
|---|---|---|
| `TriageBotCore` | Pure-Swift business logic: KBEntry/Catalog schema, LocalClassifier + TextNormalizer, ConversationReducer, ContextRedactor, TicketDraft/TicketEmailComposition, TelemetryContract, protocols. **No UIKit, no SwiftUI, no Firebase.** | Portable by design intent. Note: this is a portable Swift core, not shared code; no Kotlin exists today. A future Android port reimplements against the same protocols and the bundled `catalog.json` schema, with the quality/hold-out test corpora as the conformance contract. |
| `TriageBotIOS` | iOS-native adapters: `DefaultIosContextProvider`, `EmailTicketGateway`, `ClipboardTicketGateway`, `ClaudeFallbackClassifier`, `AnthropicKeyStore`, `OSLogTelemetrySink`. Wraps UIKit / MessageUI / OSLog / Keychain / NWPathMonitor. | iOS only. |
| `TriageBotUI` | SwiftUI chat surface: `SupportChatView`, `TriageBotViewModel`, message bubbles, KB match + guided step cards, ticket preview. | iOS only. |

## Enabling

The bot is feature-flagged via Firebase Remote Config and defaults **off** in
TestFlight/App Store builds (DEBUG builds default on). To force it on without
a Firebase round-trip:

```bash
# Simulator
xcrun simctl spawn booted defaults write org.thepalaceproject.palace \
  RemoteFeatureFlags.triageBotLocalOverride -bool true

# Then relaunch Palace. Settings -> Support -> Get Help becomes visible.
```

Three flags total: `triage_bot_enabled` (master kill-switch),
`triage_bot_ticket_submission_enabled` (transport selection, below), and
`triage_bot_ai_fallback_enabled` (Claude fallback; also requires a Keychain
API key, so it is effectively inert in App Store builds).

## Architecture in one paragraph

All state lives in `ConversationState`; all transitions are pure
`ConversationReducer.reduce(state, action) -> (state, effects)`.
`TriageBotViewModel` is the only place effects become I/O. On open, the
reducer emits `captureContext`; the snapshot (device/OS/network/log tail) is
run through `ContextRedactor` (tokens stripped, UUIDs and barcodes hashed,
prose credentials redacted) before the reducer ever holds it. The patron
picks a category and describes the issue; `LocalClassifier` scores distinct
match regions against the KB. A confident match shows a KB card, optionally
with a guided multi-step flow whose outcomes are recorded as a resolution
trace. Low confidence drafts a `TicketDraft`, optionally asking one
structured escalation follow-up first; when the AI fallback is wired, the
on-device `ClaudeFallbackClassifier` gets one shot before escalation. The
patron reviews the full draft (per-field omission, enforced at
serialization), a send-consent gate blocks rapid-tap confirms, and failed
sends persist the draft for the next session.

## Ticket transport

- `triage_bot_ticket_submission_enabled` ON: `EmailTicketGateway` presents
  the iOS Mail composer pre-addressed to `support@thepalaceproject.org` with
  `palace-diagnostics.json` + `palace-logs.txt` attached. The patron sends
  from their own account; the app never sends programmatically. Falls back
  to the clipboard gateway when `canSendMail()` is false.
- Flag OFF (production default): `ClipboardTicketGateway` copies the JSON
  payload to the pasteboard.
- **There is no HelpSpot API gateway.** Receipt ids are synthesized locally
  (`EMAIL-<epoch>` / `DEMO-CLIPBOARD-<epoch>`).

## Tests

```bash
swift test --package-path Palace/Packages/PalaceTriageBot
```

291 test functions across 39 files: 283 in `TriageBotCoreTests`
(macOS-runnable), 3 in `TriageBotIOSTests`, 5 in `TriageBotUITests` (the
latter two are UIKit-gated; real assertions run on the iOS simulator in CI).
Notable suites: `ResponseQualityTests` (recall/precision/rejection benchmark
with named-miss allowlists), `HoldoutGeneralizationTests` (blind hold-out
from real HelpSpot tickets), `RedactionCorpusTests` (deny-list leak gate,
also run by `scripts/triage-corpus-check.sh`), `CatalogSchemaLintTests`,
`HowToGovernanceTests`, `AIFallbackInertTests` (proves zero network requests
with the flag off).

## KB

`Sources/TriageBotCore/Resources/catalog.json` ships 18 hand-curated entries
(9 known-issue + 9 how_to FAQ, July 2026 corpus) sourced from real HelpSpot
tickets, with provenance pinned in each entry's `internal_reference`. Field
semantics and which fields actually drive behavior are documented in
`KBEntry.swift` and in the as-built doc. Corpus updates are a maintainer-run
editorial process gated by the schema-lint / governance / quality tests; a
corpus change ships with an app release. Server-backed hot updates would
implement `KnowledgeBaseSource`; only the bundled and in-memory sources
exist today.

## Known gaps (V1)

- No HelpSpot API integration; email is the only real transport.
- AI fallback is on-device with a device-held key; the server-proxy posture
  is future work (see the shared-architecture proposal in
  `docs/architecture/`).
- `distributor`/`authType` context fields are nil in production, so entry
  filters keyed on them never engage.
- Notify-me-on-fix is a stub; no notification is scheduled.
- Crashlytics fingerprint matching does not exist (the field is always empty).
