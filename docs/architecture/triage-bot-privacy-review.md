---
name: triage-bot-privacy-review
type: decision-record
status: pending-signoff
created: 2026-07-29
owners: [product, legal, support]
description: The recorded privacy answer for the Palace iOS triage bot. What it collects, what leaves the device and when, how long data lives, and what a patron agrees to. Written to be pointed at before the bot is enabled for patrons (PP-4884).
---

<!-- audit-verified: PP-4882/PP-4883/PP-4884/PP-4885 verified via Jira API 2026-07-29; PP-4807/PP-4809 carried from in-tree code comments (ContextRedactor/DiagnosticsPreference); file/symbol citations checked against the working tree 2026-07-29 -->

# Triage bot privacy review

This document is the durable record of the privacy question for the in-app
triage bot. It exists so the decision to enable the bot for patrons is made
against a written description of what the feature collects and what a patron
agrees to, rather than against memory of a meeting. The engineering facts below
are cited to the code that realizes them. The decision itself is recorded at the
end and is filled in by the product and legal roles, not by engineering.

Companion documents: `triage-bot-v1-as-built.md` (full behavioral contract),
`triage-bot-shared-architecture-proposal.md` (the future shared design). Gap 5
in the as-built document is the item this review closes.

## Status

The bot ships in 3.3.0 with its master flag off, so no patron sees it and no
data is collected in the field yet. This review must have a recorded answer
before that flag is turned on for patrons. As of the created date the answer is
pending.

## What the bot collects

Collection happens only after a patron opens Get Help and only for the purpose of
either answering their question on-device or assembling a support ticket they
review before sending.

When diagnostics are on (the default), the environment snapshot carries:

- App version and build, platform, OS version, device model.
- Library name and library account identifier. The account identifier is hashed
  before it is stored in state (`ContextRedactor.redact`, `libraryUUID` mapped
  through `hashIdentifier`).
- The library card number (barcode). It is hashed before it enters state and is
  never held in raw form (`ContextRedactor`, `libraryBarcode` mapped through
  `hashIdentifier`). See the open item on hash strength below.
- Network state (wifi / cellular / offline), free storage, available memory,
  low-power state, audio route, app uptime. Coarse device telemetry, no
  identifiers.
- A short tail of recent log lines from the current session (roughly the last
  five minutes). Log lines pass through the redactor before they are attached.

When diagnostics are off, none of the above beyond app version, build, OS, and
device model is captured. The full capture is not run at all: no logs are read,
no network probe runs, and no account fields are touched
(`DiagnosticsGatingContextProvider.captureSnapshot`).

The patron's free-text description is collected as typed and is redacted before
it can leave the device (free-text redaction, `ContextRedactor`).

## Redaction

Redaction runs on the device before anything is presented for sending. It strips
or hashes tokens, credentials, email addresses, account identifiers, and card
numbers from both the log tail and the free-text description. The as-built
document, section 8, holds the full pattern inventory and the conformance corpus
that keeps it honest (`RedactionCorpusTests`, `FreeTextRedactionTests`).

Redaction is content-level and always on. It is independent of the diagnostics
toggle and of the per-field omit choices described next.

## What leaves the device, and how

Nothing leaves the device without an explicit patron action. The bot classifies
on-device and, in App Store builds, makes no network call for classification
(the AI fallback is off by default and additionally requires a device key that
production builds do not carry).

When the bot cannot resolve a problem it assembles a ticket and shows the patron
the complete draft: their description, the environment fields, and the redacted
log tail. The patron can switch individual fields off and edit the description
before sending. A field switched off is absent from what is sent, on both send
paths (`TicketDraft.sanitizedForSubmission`, serialized through
`TicketWirePayload`; PP-4883 closed the copy-path gap where this was previously
honored only on the email path).

There are two send paths:

- Email. The app opens the system mail composer pre-addressed to the support
  mailbox with the body and attachments filled in. The patron sends from their
  own mail account, or cancels. The app never sends mail programmatically
  (`EmailTicketGateway`).
- Copy to clipboard. On the configuration the app currently ships (ticket
  submission off), the confirm action copies the ticket to the clipboard instead
  of opening mail (`ClipboardTicketGateway`). The patron chooses where it goes.

In both cases the transport is initiated by the patron, and the destination is
the Palace support mailbox or wherever the patron pastes.

## Retention

On the device: a ticket that fails to send is saved once as a pending draft in
app storage and re-offered the next time the chat is opened
(`UserDefaultsPendingDraftStore`, key `triagebot.pendingDraft`). It is overwritten
by the next pending draft and removed when cleared. There is no other on-device
persistence of ticket content.

Off the device: once a ticket reaches the support mailbox its retention is
governed by the support system's retention policy, not by the app. Stating that
policy, and confirming it is acceptable for the log tail and hashed identifiers
this feature sends, is part of the decision below.

## Telemetry

Separately from tickets, the bot reports coarse usage events (conversation
started, answer offered, guided step outcome, escalation). These carry only an
enumerable allow-list of keys whose values are counts or enum cases, never
patron text (`TelemetryContract.enumerableParameters`; a free-text or stale key
fails a unit test). In release builds these events go to Firebase Analytics. The
destination decision for this telemetry is tracked separately as PP-4885.

## Open items for the reviewing roles

1. Identifier hash strength. The library account identifier and card number are
   hashed with a non-cryptographic function (FNV-1a, `hashIdentifier`). This
   prevents the raw value from appearing in a ticket, but it is not a
   preimage-resistant hash, and a low-entropy card number could in principle be
   recovered by an attacker who obtains a ticket and brute-forces the space. The
   reviewing roles should decide whether this is acceptable for the threat model,
   or whether a salted or stronger hash, or omitting the identifier by default,
   is required.
2. Log tail contents. Redaction is pattern-based. The reviewing roles should
   confirm the residual risk of an un-patterned identifier in a log line is
   acceptable given the log tail is off by default when diagnostics are off and
   can be switched off per-ticket when on.
3. Default state. Diagnostics default on. The reviewing roles should confirm
   that an on-by-default posture, with a visible off switch, is the intended
   consent model, or whether collection should be off until a patron opts in.
4. Support-side retention. See Retention above.
5. Disclosure copy. The Settings toggle text and any first-run disclosure need
   product sign-off (tracked with the toggle in PP-4884).

## Decision

To be completed by the product and legal roles. This section is the recorded
answer the launch gate points at.

- Reviewed by (roles):
- Date:
- Outcome (approved to enable / approved with conditions / not approved):
- Conditions or required changes:
- Answer to each open item above:
- Reference (ticket or meeting record):
