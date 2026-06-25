---
name: epub-streaming-html-misroute
created: 2026-06-25
author: claude-opus-4-8
---

## Summary

Production regression (Palace Bookshelf): some EPUB titles — e.g.
"Multi-National Pulp Industries Within the Global Value Networks:…" — open in
the in-app WKWebView streaming reader instead of the Readium EPUB reader.

Root cause: PP-4161 (#1034, on release/3.2.0 + develop) added
`ContentTypeStreamingHTML` to the supported acquisition types. `TPPBook
.defaultBookContentType` selected `contentTypes.first(where: { $0 != .unsupported })`,
and `TPPOPDSAcquisitionPath.supportedAcquisitionPaths` preserves the OPDS feed's
indirect-acquisition order. So an open-access Palace Bookshelf title that
advertises a "read online" streaming-HTML acquisition BEFORE its `epub+zip`
now resolves to `.streamingHTML` → `isStreamingHTML == true` → BookService /
BookDetailViewModel route it to the streaming reader. Before PP-4161 the
streaming-HTML type was unsupported and skipped, so the EPUB path won — hence
the regression.

## Claims

- `TPPBook.defaultBookContentType` now selects by a fixed format preference (`.epub`, `.pdf`, `.audiobook`, then `.streamingHTML`) instead of the first supported path, so a downloadable format always beats streaming-HTML regardless of OPDS feed order
- streaming-HTML is still selected when it is the ONLY supported type (streaming-only books keep opening in the streaming reader)
- `isStreamingHTML` (derived from `defaultBookContentType`) and all routing that keys off it (BookService, BookDetailViewModel, button set) are corrected by this single change
- adds `testTPPBook_mixedStreamingAndEpub_streamingFirst_prefersEpub` (regression: streaming-HTML listed first must still resolve to `.epub`)
- adds `testTPPBook_mixedStreamingAndEpub_epubFirst_prefersEpub` (order-independence guard)

## Anti-claims

- does NOT change behavior for streaming-only books — they still resolve to `.streamingHTML`
- does NOT alter `supportedAcquisitionPaths`, `supportedSubtypes`, or the OPDS parser; the preference is applied only at `defaultBookContentType`
- does NOT change the download path's acquisition-URL selection (`MyBooksDownloadCenter` / `pathExtension`); the reported symptom is reader routing, which is driven solely by `defaultBookContentType`
- does NOT remove streaming-HTML support added by PP-4161

## Files in scope

Production:
- `Palace/Book/Models/TPPBook.swift` (`defaultBookContentType` preference selection)

Tests:
- `PalaceTests/Book/TPPBookTests.swift` (two mixed-acquisition regression tests)
