---
name: pp-4542-f012-support-fallback
created: 2026-06-08
author: claude-opus-4-8
---

## Summary

PP-4542 / F-012: `TPPSettingsView.supportSection` only renders a
`Section(header: "Support")` when `RemoteFeatureFlags.shared.isTriageBotEnabled`
is true. The production Firebase default for `triage_bot_enabled` is FALSE, so
in production the Support section never appears and users have no app-level
support path. Regression for 3.2.0.

Add an `else` branch so the Support section ALWAYS renders: when the triage bot
is OFF, show a legacy "Report an Issue" row that opens the legacy email
problem-report flow.

## Claims

- Adds a pure, testable decision type `SupportSectionDecision` with a static
  `decide(...)` that maps `(isTriageBotEnabled, currentAccount/supportEmail)` to
  `.triageBot` or `.legacyEmail(address:)`.
- Adds an `else` branch to `supportSection` so that when the bot is OFF the
  Support section STILL renders with a legacy "Report an Issue" row that opens
  `ProblemReportEmail.sharedInstance.beginComposing(...)`.
- Bot-OFF email resolution: current account's `supportEmail` if present, else
  general fallback `support@thepalaceproject.org`. Empty/nil also falls back.
- Reuses the existing localized string `Strings.Settings.reportIssue`.

## Anti-claims

- Does NOT change the bot-ON path (the "Get Help" -> TriageBotSupportView row);
  it is byte-for-byte identical.
- Does NOT introduce new user-facing copy (reuses `reportIssue`).
- Does NOT change `ProblemReportEmail`, `RemoteFeatureFlags`, or `FirebaseManager`.

## Files in scope

- Palace/Settings/NewSettings/TPPSettingsView.swift (add seam type + else branch
  + presentLegacyReportIssue / topViewController helpers)
- PalaceTests/Settings/SupportSectionDecisionTests.swift (new tests)
- Palace.xcodeproj/project.pbxproj (register the new test file)
