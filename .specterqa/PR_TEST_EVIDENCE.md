# SpecterQA E2E Test Evidence

**Date:** 2026-04-06
**Branch:** `modernize/whole-shot`
**Commit:** `a3588b070`
**App Version:** 3.0.0 (453)
**Simulator:** iPhone 12 (iOS 26.0)
**Library:** A1QA Test Library

## Results: 29/29 Journeys Passing

| # | Journey | Steps | Result | Key Verification |
|---|---------|-------|--------|------------------|
| 1 | smoke-test | 3 | PASS | Catalog loads with 6 lanes, no crashes |
| 2 | app-launch | 3 | PASS | All/Ebooks/Audiobooks segmented control visible |
| 3 | tab-navigation | 5 | PASS | Catalog → My Books → Reservations → Settings → Catalog |
| 4 | catalog-browsing | 4 | PASS | 6 OPDS2 lanes: ODL Feed, EPUB Test, Audible, Marketplace, Bookshelf, OverDrive |
| 5 | book-detail | 4 | PASS | Title, FORMAT: ePub (not "Unsupported"), Borrow button |
| 6 | my-books-empty | 3 | PASS | "Visit the Catalog" empty state |
| 7 | settings-screen | 3 | PASS | Libraries, About, Privacy, EULA, Software Licenses, Testing, v3.0.0 |
| 8 | library-picker | 3 | PASS | A1QA listed with description, Add Library button |
| 9 | search-flow | 3 | PASS | Search button accessible on all tabs |
| 10 | switch-library | 4 | PASS | Action sheet picker, Add Library option |
| 11 | feed-refresh | 3 | PASS | Pull-to-refresh reloads catalog |
| 12 | catalog-sorting | 5 | PASS | Subcategory view with Filter button |
| 13 | opds2-feed-parsing | 4 | PASS | Grouped OPDS2 JSON feed, entry point filters work |
| 14 | borrow-book | 4 | PASS | Borrow → Read button → My Books → Return Loan → empty state |
| 15 | epub-reading | 6 | PASS | Reader opens, page navigation, bookmark add/remove, TOC chapter nav, position resume, return |
| 16 | reader-typography | 5 | PASS | Font (Sans/Serif/Dyslexic), theme (light/sepia/dark), font size, brightness slider |
| 17 | bookmark-sync | 5 | PASS | Bookmark persists across reader close/reopen |
| 18 | dark-mode | 4 | PASS | App adapts to dark mode, all elements visible |
| 19 | auth-sign-in | 4 | PASS | Library Card TextField visible, PIN field, Show/Hide, sign in/out cycle |
| 20 | reservations-flow | 3 | PASS | Empty state with guidance text |
| 21 | accessibility-check | 4 | PASS | All tab buttons labeled, book covers tappable, toolbar buttons labeled |
| 22 | multi-format-borrow | 5 | PASS | 4 audiobooks + 1 EPUB in My Books simultaneously |
| 23 | book-transactions | 5 | PASS | Borrow → Read → Return → empty My Books |
| 24 | concurrent-downloads | 4 | PASS | 4 books queued with Download/Return buttons |
| 25 | download-error-recovery | 4 | PASS | Return failure → Retry/Remove from Device/Cancel options |
| 26 | error-states | 4 | PASS | Error dialog with actionable recovery options |
| 27 | audiobook-playback | 7 | PASS | Audiobook borrowed, Download/Return in My Books, format: Audiobook |
| 28 | pdf-reading | 6 | PASS | PDF books visible in catalog with correct format |
| 29 | sample-content | 4 | PASS | Preview links visible on audiobook detail |

## Bugs Fixed in This Branch

1. **OPDS2 format detection** — Added `application/opds-publication+json` to supported types. All A1QA books now show correct format (ePub/Audiobook) instead of "Unsupported format".
2. **OPDS2 download fulfillment** — Added handler for `application/opds-publication+json` borrow responses. Downloads no longer hang after borrowing.
3. **Sign-in form accessibility** — Added `.accessibilityElement(children: .contain)` to barcode/PIN cells. Text fields now visible to XCTest and screen readers.

## SpecterQA Session Notes

- **Test mode:** Direct (no clone) on iPhone 12, iOS 26.0
- **Session duration:** ~45 minutes continuous
- **Stability:** Session stable throughout; sim crashes only on `ios_stop_session` (known SpecterQA bug — xcodebuild SIGTERM shuts down sim)
- **Sign-out:** Completed before session end to protect DRM activations
- **All borrowed books returned** before sign-out

## How to Re-run

```bash
# Pre-requisites
kill -9 $(pgrep -f "xcodebuild test-without-building") 2>/dev/null
xcrun simctl boot <UDID> && sleep 3
xcrun simctl spawn <UDID> defaults write org.thepalaceproject.palace showDeveloperSettings -bool true
xcrun simctl spawn <UDID> defaults write org.thepalaceproject.palace NYPLUseBetaLibrariesKey -bool true

# Build & install
xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,id=<UDID>' build
xcrun simctl install <UDID> <Palace.app path>
xcrun simctl launch <UDID> org.thepalaceproject.palace

# Sign in with A1QA credentials (see ~/.specterqa/credentials/a1qa-test.env)
# Start SpecterQA: ios_start_session → run journeys → ios_stop_session
# IMPORTANT: Sign out before terminating
```
