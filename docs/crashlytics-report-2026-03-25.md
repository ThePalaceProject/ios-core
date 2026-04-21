# Crashlytics Report — Palace iOS 2.2.2 (build 446)
### Content Protection Error Investigation — March 24–25, 2026
**Prepared:** March 25, 2026  
**Related ticket:** PP-3970 / HelpSpot #17425

---

## Executive Summary

Three Crashlytics queries were run against Palace iOS version 2.2.2 (build 446) covering the incident timestamps (March 24 ~12:15 PM CT and March 25 ~1:09 PM CT) and the full 2.2.2 release lifetime.

**Key finding: The "Content Protection Error" alert has no Crashlytics instrumentation in 2.2.2.** The code path that shows this error calls `TPPAlertUtils.alert(title: "Content Protection Error", ...)` and logs nothing to Firebase. This error is invisible to Crashlytics for any user on any device across the entire 2.2.2 release. A fix adding logging to this path is in PR #812.

No LCP-specific errors (codes 1002 `lcpDRMFulfillmentFail`, 1003 `lcpPassphraseAuthorizationFail`, 1004 `lcpPassphraseRetrievalFail`) appear anywhere in any of the three queries.

---

## Query 1 — Tablets Only, March 24–25 Incident Window

**Parameters:** Version 2.2.2 (446) · Device form factor: TABLET · March 24 17:00 UTC → March 25 20:00 UTC

| Rank | Issue | Error Code | Events | Impacted Users |
|------|-------|-----------|--------|----------------|
| 1 | Network request failed: Problem Document available | 912 | 110 | 71 |
| 2 | Error posting annotation | 902 | 83 | 51 |
| 3 | Audiobook failed to open — showing try again error | 401 | 40 | 20 |
| 4 | NYPLOPDSFeed: Failed to parse data as XML | 604 | 34 | 32 |
| 5 | Request Cancelled | 911 | 29 | 20 |
| 6 | Authentication Document request failed to load | 700 | 24 | 18 |
| 7 | Logo image failed to load | 700 | 19 | 5 |
| 8 | Error retrieving user profile document | 902 | 11 | 9 |
| 9 | Network request failed: Problem Document available | 608 | 5 | 5 |
| 10 | Error reading PDF path | 0 | 3 | 3 |
| 11 | SignIn error: problem document available | 303 | 2 | 2 |
| 12 | Request Timeout | 910 | 1 | 1 |
| 13 | Error uploading audiobook tracker data | 4864 | 1 | 1 |
| 14 | Error: unable to create URL for signing out | 900 | 1 | 1 |
| 15 | NSInternalInconsistencyException crash (FATAL) | — | 1 | 1 |

**LCP-related events (1002, 1003, 1004): NONE**

---

## Query 2 — All Devices, March 24–25 Incident Window

**Parameters:** Version 2.2.2 (446) · All device types · March 24 17:00 UTC → March 25 20:00 UTC

| Rank | Issue | Error Code | Events | Impacted Users |
|------|-------|-----------|--------|----------------|
| 1 | Error posting annotation | 902 | 1,770 | 680 |
| 2 | Network request failed: Problem Document available | 912 | 870 | 530 |
| 3 | Audiobook failed to open — showing try again error | 401 | 590 | 390 |
| 4 | Request Cancelled | 911 | 327 | 209 |
| 5 | NYPLOPDSFeed: Failed to parse data as XML | 604 | 325 | 307 |
| 6 | Error retrieving user profile document | 902 | 115 | 81 |
| 7 | Authentication Document request failed to load | 700 | 112 | 83 |
| 8 | Network request failed: Problem Document available | 608 | 92 | 65 |
| 9 | Logo image failed to load | 700 | 67 | 25 |
| 10 | Request Timeout | 910 | 54 | 33 |
| 11 | Connection Lost/Severed | 910 | 54 | 40 |
| 12 | SignIn error: problem document available | 303 | 47 | 20 |
| 13 | Overdrive audiobook fulfillment: wrong headers | 609 | 22 | 4 |
| 14 | Error retrieving user profile document (914) | 914 | 18 | 18 |
| 15 | SignIn error: Adobe activation | 307 | 18 | 6 |
| 16 | Error alert shown to user: Login Failed | 5 | 16 | 4 |
| 17 | NSInternalInconsistencyException crash (FATAL) | — | 11 | 9 |
| 18 | Error uploading audiobook tracker data | 4864 | 11 | 6 |
| 19 | Error parsing user profile document | 4864 | 6 | 6 |
| 20 | std::system_error recursive_mutex lock failed (FATAL) | — | 6 | 4 |

**LCP-related events (1002, 1003, 1004): NONE**

---

## Query 3 — All Devices, Full 2.2.2 Lifetime

**Parameters:** Version 2.2.2 (446) · All device types · January 5, 2026 → March 25, 2026

| Rank | Issue | Error Code | Events | Impacted Users |
|------|-------|-----------|--------|----------------|
| 1 | Error parsing catalog feed | 0 | 49,550 | 1,495 |
| 2 | Error posting annotation | 902 | 16,590 | 3,474 |
| 3 | Network request failed: Problem Document available | 912 | 8,277 | 3,547 |
| 4 | Audiobook failed to open — showing try again error | 401 | 5,064 | 2,019 |
| 5 | Request Cancelled | 911 | 3,287 | 1,542 |
| 6 | NYPLOPDSFeed: Failed to parse data as XML | 604 | 2,947 | 2,038 |
| 7 | Authentication Document request failed to load | 700 | 1,058 | 637 |
| 8 | Error retrieving user profile document | 902 | 1,022 | 376 |
| 9 | Request Timeout | 910 | 908 | 380 |
| 10 | Network request failed: Problem Document available | 608 | 851 | 417 |
| 11 | SignIn error: problem document available | 303 | 685 | 248 |
| 12 | Logo image failed to load | 700 | 570 | 198 |
| 13 | Connection Lost/Severed | 910 | 563 | 352 |
| 14 | Overdrive audiobook fulfillment: wrong headers | 609 | 175 | 38 |
| 15 | NSInternalInconsistencyException crash (FATAL) | — | 142 | 93 |
| 16 | Error retrieving user profile document (914) | 914 | 114 | 110 |
| 17 | NSInternalInconsistencyException scroll crash (FATAL) | — | 114 | 65 |
| 18 | Error while trying to show/hide the PIN | -2 | 108 | 82 |
| 19 | std::system_error recursive_mutex lock failed (FATAL) | — | 108 | 22 |
| 20 | Accounts list failed to load | 902 | 94 | 57 |

**LCP-related events (1002, 1003, 1004): NONE — across the entire 2.2.2 release lifetime.**

---

## Sample Events — Top Issue: "Problem Document available" (912)

This issue (annotation sync failures returning HTTP 400) was the #2 issue across all devices during the incident window. Sample events confirm it is **not related** to content protection — it is annotation bookmark sync failing because the CM rejects sync requests for books that are no longer in the patron's active loans. Unrelated to the "Content Protection Error."

**Sample event 1** — iPad Air (4th Gen), iPadOS 26.3.1, 2026-03-25 19:32 UTC  
Library: Middle Georgia Regional Library (`ga.thepalaceproject.org/GA0004`)  
Error: `POST /GA0004/annotations/ → HTTP 400 "The annotation target must be a work in your current loans."`  
Problem doc type: `http://librarysimplified.org/terms/problem/invalid-annotation-target`

**Sample event 2** — iPhone 12, iOS 26.3.1, 2026-03-25 19:57 UTC  
Library: Stratford Library Association (`ct.thepalaceproject.org/CT0154`)  
Error: `POST /CT0154/annotations/ → HTTP 400 "The annotation target must be a work in your current loans."`  
Problem doc type: `http://librarysimplified.org/terms/problem/invalid-annotation-target`

**Sample event 3** — iPhone 16 Pro, iOS 26.3.1, 2026-03-25 19:56 UTC  
Library: Flint River Regional Library (`ga.thepalaceproject.org/GA0042`)  
Error: `GET /GA0042/patrons/me/devices/ → HTTP 404 "Patron does not have a device registered with this token."`  
Problem doc type: `http://librarysimplified.org/terms/problem/device-token-not-found`

---

## Sample Events — "Audiobook failed to open" (401) on Tablets

**Sample event — iPad (11th Gen), iPadOS 26.3.1, 2026-03-25 19:01 UTC**  
Library: Lexington Public Library District, IL (`il.thepalaceproject.org/IL0289`)  
Error: `AudiobookOpenError Code=401 "Failed to open audiobook"`  
Device: `iPad15,7` | PalaceDeviceID: `4B798D8A-31FE-447B-B07A-6C3AD1ED6CA8`

**Sample event — iPad (9th Gen), iPadOS 26.3.1, 2026-03-25 18:23 UTC**  
Library: RAILS eRead Elementary School Library (`il.thepalaceproject.org/IL9993`)  
Device: `iPad12,1` | PalaceDeviceID: `23008778-DAE0-4A1E-B7CA-E3629EFF83A9`  
Console log extract:
```
[INFO]  Auth token expired for audiobook - refreshing before opening
[INFO]  Token refresh successful - re-fetching manifest with fresh token
[INFO]  GET /IL9993/works/515440/fulfill/15 → completed (1.054s)
[ERROR] Failed to parse manifest data as JSON dictionary
[ERROR] Failed to re-fetch manifest after token refresh
[WARNING] Showing 'An error was encountered while trying to open this book' alert
```
*(The fulfill endpoint returned an LCPL file; the app attempted to parse it as an audiobook manifest JSON.)*

---

## Instrumentation Gap

The "Content Protection Error" alert shown to the patron is triggered by this code path in `ReaderService.swift` (Palace 2.2.2):

```swift
// No logging — error silently swallowed after this line
let alert = TPPAlertUtils.alert(title: "Content Protection Error",
                                message: error.localizedDescription)
TPPAlertUtils.presentFromViewControllerOrNil(...)
```

This path exists at two locations in `ReaderService.swift` (EPUB open failure and sample open failure). Neither calls `TPPErrorLogger`. As a result, **zero "Content Protection Error" events exist in Crashlytics for any user across the entire 2.2.2 release.** 

Additionally, LCP-specific error codes logged elsewhere in the codebase (`lcpPassphraseRetrievalFail` = 1004, `lcpDRMFulfillmentFail` = 1002, `lcpPassphraseAuthorizationFail` = 1003) do not appear in any of the three queries, indicating these sub-paths were also not triggered during the incident window.

**Fix status:** PR #812 adds Crashlytics logging to the "Content Protection Error" path, capturing the specific `LCPError` case, book identifier, and error description. The next occurrence will produce a traceable event in Firebase.

---

## Firebase Console Links

- **Top Issues (tablets, incident window):** [Firebase Console](https://console.firebase.google.com/project/the-palace-project/crashlytics/app/ios:org.thepalaceproject.palace/issues?time=1774371600000:1774468800000&versions=2.2.2%20(446))
- **"Audiobook failed to open" issue:** [Firebase Console](https://console.firebase.google.com/project/the-palace-project/crashlytics/app/ios:org.thepalaceproject.palace/issues/27f5746256446e635a62d2ba5e31da32)
- **"Problem Document available (912)" issue:** [Firebase Console](https://console.firebase.google.com/project/the-palace-project/crashlytics/app/ios:org.thepalaceproject.palace/issues/a28b442be3866caafc936525666d7f92)
- **PR #812 (adds Content Protection Error logging):** https://github.com/ThePalaceProject/ios-core/pull/812
