---
name: default-acquisition-prefer-downloadable
created: 2026-06-25
author: claude-opus-4-8
---

## Summary

Follow-up to the EPUB-as-webview regression (RC #1117). #1117 fixed
`defaultBookContentType`'s OPDS2 indirect-acquisition ordering, but **that did
not fix the actual reported book** ("Multi-National Pulp Industries…" on Palace
Bookshelf). Verified against the LIVE OPDS feed
(`https://dpla.thepalaceproject.org/bookshelf/`): the book is OPDS **1.x** with
many flat `open-access` links — streaming-media, PDF and EPUB as SEPARATE
acquisitions, streaming-media FIRST.

`defaultBookContentType` only inspects `defaultAcquisition`, and
`defaultAcquisition` was `acquisitions.first(where: hasSupportedPath)`. PP-4161
made streaming-media a *supported* type, so `defaultAcquisition` became the
first (streaming) link → `.streamingHTML` → WKWebView reader. Confirmed fixed
end-to-end via simdrive on a signed release/3.2.0+fix build: the book now opens
in the Readium EPUB reader.

## Claims

- `TPPBook.defaultAcquisition` now ranks supported acquisitions by a fixed format preference (`.epub`, `.pdf`, `.audiobook`, then `.streamingHTML`) and returns the highest-preference one, instead of the first supported in feed order
- streaming-media is selected only when it is the sole supported acquisition (streaming-only books unaffected)
- adds private helpers `isSupportedDefaultAcquisition(_:)` and `defaultAcquisitionContentType(_:)` to rank candidates with the default-acquisition relation set
- because `defaultBookContentType`, `isStreamingHTML`, the Read-button routing (BookService / BookDetailViewModel) and the download URL all derive from `defaultAcquisition`, this corrects both the reader chosen AND the file downloaded
- adds `testTPPBook_openAccessSeparateLinks_streamingFirst_defaultsToEpub` (the real multi-link shape), `_fallsBackToPDF`, and `_streamingOnly_staysStreaming`

## Anti-claims

- does NOT revert or change #1117's `defaultBookContentType` preference (that still correctly handles the OPDS2 single-acquisition-with-indirects shape)
- does NOT change behavior for streaming-only books — they still resolve to `.streamingHTML`
- does NOT alter `supportedAcquisitionPaths`, `supportedSubtypes`, the OPDS parser, or PP-4161 streaming support
- does NOT change availability/expiration semantics — all open-access links for a work share the same availability, so ranking by format does not affect them

## Files in scope

Production:
- `Palace/Book/Models/TPPBook.swift` (`defaultAcquisition` preference + two private helpers)

Tests:
- `PalaceTests/Book/TPPBookTests.swift` (three OPDS1 separate-link regression tests)
