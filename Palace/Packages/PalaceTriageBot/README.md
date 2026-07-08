# PalaceTriageBot

In-app triage and support chatbot for Palace. iOS-first demo build that
auto-resolves common known-issue tickets before they reach a human triager
and captures structured context on the ones that do escalate.

## Why three products

| Product | Contents | Reusability |
|---|---|---|
| `TriageBotCore` | Pure-Swift business logic — KBEntry/Catalog schema, LocalClassifier, ConversationReducer, ContextRedactor, protocols. **No UIKit, no SwiftUI, no Firebase.** | KMP-portable: every type and protocol has a 1:1 Kotlin analogue. The bundled `catalog.json` is the shared schema. |
| `TriageBotIOS` | iOS-native adapters — `DefaultIosContextProvider`, `ClipboardTicketGateway`, `OSLogTelemetrySink`. Wraps UIKit / OSLog / NWPathMonitor. | iOS only. Android writes its own adapters implementing the same protocols. |
| `TriageBotUI` | SwiftUI chat surface — `SupportChatView`, `TriageBotViewModel`, message bubbles, KB cards, ticket preview. | iOS only. Android writes Compose UI. The shape (categories, KB match card, ticket preview) is documented so both stay aligned. |

The 70 / 30 split between portable Core and iOS-only adapter/UI is the
point: when the KMP port opens up, the Kotlin module reuses everything in
`Core` and re-implements only the iOS-specific layers.

## Enabling for the demo

The bot is feature-flagged via Firebase Remote Config and defaults to **off**.

To enable in a TestFlight or simulator build without a Firebase round-trip:

```bash
# Simulator
xcrun simctl spawn booted defaults write org.thepalaceproject.palace \
  RemoteFeatureFlags.triageBotLocalOverride -bool true

# Then relaunch Palace. Settings → Support → Get Help becomes visible.
```

For production rollout, set `triage_bot_enabled` to `true` in the
Firebase Remote Config console. The secondary flag
`triage_bot_ticket_submission_enabled` gates real HelpSpot submission;
when off (default), confirmed tickets copy their JSON payload to the
pasteboard so the flow stays exercisable without poking HelpSpot.

## Architecture in one paragraph

The user opens chat. `TriageBotViewModel.send(.start)` triggers the reducer,
which appends a welcome message + category chips and emits a
`.captureContext` effect. The host runs the effect via `DefaultIosContextProvider`,
which snapshots build/version/device/network/log lines and feeds the
result back through `.contextLoaded`. The reducer runs the snapshot through
`ContextRedactor` (strips tokens, hashes UUIDs, redacts emails). User taps
a category → describes the issue → `LocalClassifier` runs keyword overlap
against `KnowledgeBase.entries(in: category)` filtered by distributor/auth.
High-confidence match → KB card. Low confidence or no match → `TicketDraft`
with the redacted context. User confirms send → `ClipboardTicketGateway`
serializes the draft to pasteboard + returns a synthesized receipt.

All state lives in `ConversationState`; all transitions are described by
pure `ConversationReducer.reduce(state, action) -> (state, effects)`. The
host runs effects but doesn't decide anything.

## Tests

```bash
swift test --package-path Palace/Packages/PalaceTriageBot
```

26 tests passing — 10 redactor (privacy gate), 8 classifier (match /
disambiguate / escalate behavior, filter exclusion), 7 reducer (round-trip
flows including notify-me, file-anyway, escalate→submit→receipt, submission
failure, redactor integration), 1 UI placeholder.

## KB schema

`Sources/TriageBotCore/Resources/catalog.json` ships 8 hand-curated entries
from May 2026 HelpSpot triage. Each entry has the YAML-equivalent fields
documented in `KBEntry.swift`:

- `symptom_keywords` — string list, classifier scores keyword overlap
- `distributor_filter` / `auth_type_filter` — optional, narrows candidates
- `status` — `open` / `fixed_in` / `wontfix` / `user_error` / `duplicate_of`
- `fixed_in_version` — surfaces "update your app" when applicable
- `confidence_threshold` — per-entry suggest-vs-escalate gate
- `trust_level` — `authoritative` / `signal` / `context` (Phase 2)
- `visibility` — `user_facing` / `internal_only` (Phase 2)

Server-backed hot updates implement `KnowledgeBaseSource` and drop in
without touching the rest of the system.

## What's NOT in the demo

- Server-side endpoints (KB hosting, AI fallback, cluster detector) —
  Phase 2; the protocol seam (`KnowledgeBaseSource`) is in place
- HelpSpot real-submission gateway — Phase 2; `ClipboardTicketGateway` is
  the demo fallback
- Android client — Phase 2; the Core module is KMP-portable on purpose
- Crashlytics fingerprint matching — Phase 2
- Per-library KB overrides — Phase 3
