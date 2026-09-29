---
name: pp-5242-playback-failure-cause
created: 2026-09-24
author: Maurice Carrier
branch: fix/PP-5242-playback-failure-cause
priority: PP-5242 (audiobook playback diagnostics)
---

# Intent: record the cause of an audiobook playback failure, and record each failure once

## Context

The Crashlytics non-fatal for `.playbackFailed` keeps only the top-level error
domain/code. AVFoundation replaces a resource-loader error's domain with
`NSURLErrorDomain`/`AVFoundationErrorDomain` and keeps the original code only as
`NSUnderlyingError` (`NSOSStatusErrorDomain`), so the cause is not in the record.
Counts are inflated by repeat reports of the same failure.

## Claims

- The record gains `underlyingErrorDomain`/`underlyingErrorCode` for each level of
  the `NSUnderlyingErrorKey` chain, bounded at three levels.
- The record gains `contentSource` (lcpStreamed / lcpLocal / overdrive / findaway /
  openAccess / unknown), captured when the audiobook is bound.
- The record gains `atTrackStart`.
- The record gains `msSincePreviousFailureForBook` when an earlier failure for the
  same book arrived within the repeat window.
- A failure with the same (bookId, domain, code, underlyingDomain, underlyingCode)
  as one seen within the previous 60 seconds is not recorded again. The
  underlying pair is part of the key because AVFoundation collapses every
  resource-loader failure into `AVFoundationErrorDomain -11800`, so keying on
  the top level alone would suppress exactly the distinctions this change adds.

- The audiobook open-failure non-fatal (`BookService.showAudiobookTryAgainError`)
  gains `loadError`, `contentSource`, and the cause fields of the error the load
  error carries, built by the same helper as the playback record. Its domain and
  code are unchanged.
- The five audiobook-fulfillment log sites that passed `book.loggableDictionary`
  unapplied (OverDrive x2, LCP x3) now call it.

## Known gaps

- The SAML re-auth fallback (`AudiobookSessionManager.swift`) still reports the
  open failure with no metadata: `[String: Any]` is not `Sendable` and the call
  sits inside an `@Sendable` closure. A `Sendable` metadata carrier would
  unblock it.

## Anti-claims

- Existing record keys, domain and code are unchanged.
- Failures with a different code are still recorded (no follow-up suppression).
- No change to recovery control flow, position saving, or the Firebase API.

## Files in scope

- Palace/Audiobooks/AudiobookPlaybackFailureRecord.swift (new)
- Palace/Audiobooks/AudiobookSessionManager.swift
- PalaceTests/Audiobook/AudiobookPlaybackFailureRecordTests.swift (new)
- Palace.xcodeproj/project.pbxproj
- Palace/Book/UI/BookDetail/BookService.swift
- Palace/MyBooks/OverdriveDownloadHandler.swift
- Palace/MyBooks/LCPFulfillmentHandler.swift
