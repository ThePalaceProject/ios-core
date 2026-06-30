---
name: pp-1916-pdf-lazy-thumbnails
created: 2026-06-30
author: claude-opus-4-8
---

# Intent: PP-1916 — lazy-load the PDF bottom thumbnail bar + modernize reader chrome

## Problem
The non-VoiceOver PDF reader's bottom bar (`TPPPDFView` → `TPPPDFThumbnailView` →
PDFKit `PDFThumbnailView`) eagerly rasterizes a thumbnail for every page when the
document is assigned. On a large title ("Malcom Kid and the Perfect Song") this is
slow and crashes. Goal: lazy-load thumbnails (render only visible ones) without
removing the bar, and modernize the reader chrome layout.

## Claims
- Added `PDFKitThumbnailProvider`, a concrete `ObservableObject`: on-demand
  per-page thumbnail rendering on a background queue with an `NSCache`; no eager
  all-pages pass.
- Added `PDFThumbnailStrip` SwiftUI view: a horizontal `LazyHStack` (only visible
  cells instantiated) of page thumbnails, current-page binding, tap-to-seek, and
  auto-scroll to the current page.
- Replaced the eager `TPPPDFThumbnailView` (PDFKit) in `TPPPDFView` with
  `PDFThumbnailStrip`.
- Modernized the reader chrome: `TPPPDFLabel` uses a translucent dark capsule
  (reliable + readable over arbitrary PDF pages; SwiftUI materials render
  unreliably over the `PDFView` UIViewRepresentable backdrop), and the strip uses
  a solid system background for the same reason.
- Deleted dead code superseded by this work: `TPPPDFPreviewBar`,
  `TPPPDFPreviewThumbnail`, `TPPPDFThumbnailView`, the `PDFDocumentProviding`
  protocol, and its test-only `MockPDFDocument`.

## Anti-claims
- Does NOT change the full-screen previews/bookmarks grid
  (`TPPPDFPreviewGridController`) — already lazy.
- Does NOT change the VoiceOver path (`TPPPDFAccessibilityToolbar`) behavior.
- Does NOT change the LCP/Readium-publication PDF pipeline (`ReadiumPDFReaderView`).
- Does NOT change page-sync, bookmark, search, or DRM-copy gating behavior.

## Files in scope
- `Palace/PDF/Model/PDFKitThumbnailProvider.swift` (new)
- `Palace/PDF/Views/PDFThumbnailStrip.swift` (new)
- `Palace/PDF/Views/TPPPDFView.swift`
- `Palace/PDF/Views/TPPPDFLabel.swift`
- `Palace/PDF/Views/TPPPDFPreviewBar.swift` (delete)
- `Palace/PDF/Views/TPPPDFPreviewThumbnail.swift` (delete)
- `Palace/PDF/Views/TPPPDFThumbnailView.swift` (delete)
- `Palace/PDF/Model/PDFDocumentProviding.swift` (delete)
- `PalaceTests/Mocks/MockPDFDocument.swift` (delete)
- `PalaceTests/PDF/PDFKitThumbnailProviderTests.swift` (new)
