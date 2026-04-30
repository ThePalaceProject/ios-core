# SpecterQA Automated Regression Plan

**Mirrors:** PP-4020 manual regression test plan at ~/Desktop/regression-PP-4020/PLAN.md
**Branch:** fix/per-account-user-credentials (combined: whole-shot + all PRs)
**Simulator:** iPhone 12 (31CF5C43-DD55-4889-B3B2-9A6810B4E98F, iOS 26)

## Execution Order

Run journeys in this order. Each journey starts a fresh SpecterQA session.
Kill stale runners between sessions: `pgrep -f "xcodebuild test-without-building" | xargs -r kill -9`

### Tier 1: Critical Path (must pass before any release)

| # | Test Area | Journey | PP-4020 IDs |
|---|-----------|---------|-------------|
| 1 | App launch | app-launch.yaml | Smoke |
| 2 | Tab navigation | tab-navigation.yaml | Smoke |
| 3 | Catalog browsing | catalog-browsing.yaml | C7 |
| 4 | Search | search-flow.yaml | C1 |
| 5 | Sign in | sign-in-basic.yaml | A1 |
| 6 | Borrow book | borrow-book.yaml | C2 |
| 7 | Return loan | return-loan.yaml | C6 |
| 8 | Book detail | book-detail.yaml | C2, U1 |
| 9 | EPUB reading | epub-reading.yaml | R1 |
| 10 | Audiobook playback | audiobook-playback.yaml | L1-L4 |
| 11 | Place/cancel hold | place-hold.yaml | C3, C4, PP-4033 |
| 12 | Sign out | sign-out.yaml | A3 |

### Tier 2: Multi-account and Security

| # | Test Area | Journey | PP-4020 IDs |
|---|-----------|---------|-------------|
| 13 | Add library | library-picker.yaml | M1 |
| 14 | Switch library | switch-library.yaml | M2 |
| 15 | Credential isolation | credential-isolation.yaml | M3, F-034, ADV-1 |

### Tier 3: Edge Cases and Persistence

| # | Test Area | Journey | PP-4020 IDs |
|---|-----------|---------|-------------|
| 16 | Offline mode | offline-mode.yaml | N1 |
| 17 | Catalog filter | catalog-filter.yaml | C7 |
| 18 | Settings screen | settings-screen.yaml | U1 |
| 19 | Bookmarks | bookmark-add-and-restore.yaml | P1 |
| 20 | Reading position | persistence-reading-position.yaml | P2 |
| 21 | Book transactions | book-transactions.yaml | D1-D4 |
| 22 | Feed refresh | feed-refresh.yaml | C7 |
| 23 | Smoke test | smoke-test.yaml | Full |

### Not Automatable via SpecterQA

| Test Area | PP-4020 ID | Reason |
|-----------|------------|--------|
| Phone call interruption | B2 | Requires real phone call |
| Notifications | NT1-NT3 | Requires APNs push |
| Multi-device sync | P5 | Requires second device |
| Performance profiling | PR1-PR5 | Requires Instruments |
| Hold conversion | C5 | Requires waiting for availability |
| Adversarial rapid switch | M5, ADV-1 | Partially covered by credential-isolation; full concurrent stress requires unit tests |

## Coverage Summary

| Category | Total Tests | Automated | Manual Only |
|----------|------------|-----------|-------------|
| Authentication (A1-A4) | 4 | 2 (sign-in, sign-out) | 2 (JIT popup, error states) |
| Reading (R1-R4) | 4 | 1 (EPUB) | 3 (Adobe, LCP, PDF need specific content) |
| Listening (L1-L4) | 4 | 1 (generic) | 3 (vendor-specific) |
| Catalog (C1-C7) | 7 | 6 | 1 (hold conversion) |
| Multi-account (M1-M5) | 5 | 4 | 1 (adversarial, unit test) |
| Connectivity (N1-N4) | 4 | 1 (offline) | 3 |
| Downloads (D1-D4) | 4 | 1 (transactions) | 3 |
| Background audio (B1-B6) | 6 | 0 | 6 |
| Notifications (NT1-NT3) | 3 | 0 | 3 |
| Persistence (P1-P5) | 5 | 2 (bookmarks, position) | 3 |
| UI completeness (U1) | 1 | 0 (partial via snapshots) | 1 |
| Performance (PR1-PR5) | 5 | 0 | 5 |
| **Total** | **52** | **18 (35%)** | **34** |

## New Journeys Added

- `place-hold.yaml` - C3, C4, PP-4033
- `return-loan.yaml` - C6
- `credential-isolation.yaml` - M3, F-034, ADV-1
- `persistence-reading-position.yaml` - P1, P2
