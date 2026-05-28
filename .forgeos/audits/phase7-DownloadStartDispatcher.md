---
name: audit-phase7-DownloadStartDispatcher
type: ephemeral
status: active
created: 2026-05-26
last_refresh: 2026-05-26
freshness_window: 180d
owners: [mybooks]
description: Phase 7 audit — DownloadStartDispatcher.swift
---

# Phase 7 audit — DownloadStartDispatcher.swift

## Summary

**Verdict: 0 BUG / 6 NEEDS-TEST / 1 CLEAN.**

Production logic in `Palace/MyBooks/DownloadStartDispatcher.swift` is a faithful
lift of 3.0.2's `MyBooksDownloadCenter.processUnregisteredState /
processDownloadWithCredentials / processRegularDownload`. Every conditional in
the current file matches the pre-Phase-7 expression byte-for-byte (modulo
delegate-routing). **No F-011 / F-014 / F-017-class defect is present.**

However, `PalaceTests/MyBooks/DownloadStartDispatcherTests.swift` (256 lines,
11 tests) leaves six concrete F-014-class mutants unkilled. None of them are
catastrophic individually, but the pattern that lets F-014 slip past CI in the
first place is "extraction landed, tests pass, but a flipped condition would
still pass." Recommendation: add the six tests sketched below before the next
extraction pass in this file's neighborhood.

---

## File:line citations and findings

### Production file `Palace/MyBooks/DownloadStartDispatcher.swift`

Reference points throughout: 3.0.2 inline source is at
`git show 3.0.2:Palace/MyBooks/MyBooksDownloadCenter.swift` lines 434–700.

| # | Conditional | Current line | 3.0.2 line | Identical? |
|---|---|---|---|---|
| 1 | `book.defaultAcquisitionIfBorrow == nil && (book.defaultAcquisitionIfOpenAccess != nil \|\| !(loginRequired ?? false))` | L101 | L435 | YES |
| 2 | `state == .unregistered \|\| state == .holding` → startBorrow | L121 | L508 | YES |
| 3 | `book.distributor == OverdriveDistributorKey && book.defaultBookContentType == .audiobook` | L126 | L513 | YES |
| 4 | `MyBooksDownloadCenter.shouldDeferOverdriveFulfillment(for:state:)` (delegated) | L127 | L514 (inline) | YES (delegates to same static) |
| 5 | `currentBook.isExpired && currentBook.defaultAcquisitionIfBorrow != nil` | L152 | L633 | YES |
| 6 | `state == .downloadNeeded && currentBook.defaultAcquisitionIfBorrow != nil` | L159 | L642 | YES |
| 7 | Auto-borrow completion check: `newState != .downloading && newState != .downloadSuccessful && newState != .downloadNeeded` | L166 | L655 | YES |
| 8 | `isWifiOnlyEnforced` guard | L173 | L660 | YES (now via injected `isOnWiFi: () -> Bool` closure) |
| 9 | Request resolution: prefer `initedRequest`, else `currentBook.defaultAcquisition?.hrefURL`, else logInvalidURL | L178–186 | L666–674 | YES |
| 10 | `guard request.url != nil` | L188 | L676 | YES |
| 11 | `memoryPressureMonitor.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 512)` | L198 | L688 | YES |
| 12 | `state == .SAMLStarted, let cookies = userAccount.cookies` | L200 | L687 | YES |

**F-011 (missing enum case via `default:`)** — *impossible by construction* in
this file. There is no `switch` statement on `TPPBookState` anywhere in
`DownloadStartDispatcher.swift`. All state checks are explicit `==` /
`!=` equality. This is the **CLEAN** finding.

**F-014 (inverted condition)** — see NEEDS-TEST entries below; no live bug
present, but several conditions are insufficiently pinned by tests.

**F-017 (missing state observation)** — *not applicable*. `DownloadStartDispatcher`
publishes nothing (`@Published` count = 0), exposes no Combine subjects, and
is invoked imperatively from `MyBooksDownloadCenter.startDownloadAsync`. There
is no readiness-gate / state-observation surface to mis-wire.

---

## NEEDS-TEST findings (6)

All six describe **F-014-class mutants** (flipped operator / equality) that
the current `DownloadStartDispatcherTests` would NOT catch.

### NT-1 — `processRegularDownload` expired-re-borrow branch is untested

**File:** `Palace/MyBooks/DownloadStartDispatcher.swift:152`

```swift
if currentBook.isExpired && currentBook.defaultAcquisitionIfBorrow != nil {
    ...
    delegate.startBorrow(for: currentBook, attemptDownload: true, borrowCompletion: nil)
    return
}
```

**Surviving mutants:**
- Flip `&&` to `||` (would re-borrow on every expired book, even those
  without a borrow link — would silently regress fulfillment-only titles).
- Drop the `isExpired` check (would re-borrow on EVERY borrowable book,
  conflating with the auto-borrow branch at L159).
- Flip `!= nil` to `== nil` (would never re-borrow expired books, leaving
  the user with a stale entry).

**No existing test invokes the expired branch.** `TPPBook.isExpired` reads
the acquisition availability; the test helpers in
`DownloadStartDispatcherTests.swift:91–125` (`makeBook`) always pass
`TPPOPDSAcquisitionAvailabilityUnlimited()`, so `isExpired == false` for
every test book.

**Suggested fix:**

```swift
func testProcessRegularDownload_expiredBookWithBorrowLink_triggersReBorrow() {
    let book = makeBook(
        relation: .borrow,
        availability: TPPOPDSAcquisitionAvailabilityUnavailable(
            untilDate: Date(timeIntervalSinceNow: -86400) // yesterday
        )
    )
    registry.addBook(book, location: nil, state: .downloadSuccessful, ...)

    dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

    XCTAssertEqual(spyDelegate.startBorrowCalls.count, 1)
    XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty,
                  "Expired-rebborrow must NOT addDownloadTask itself")
    XCTAssertEqual(registry.state(for: book.identifier), .unregistered,
                   "Expired re-borrow must reset registry state to unregistered")
}
```

Plus a negative test where an expired book WITHOUT a borrow link falls
through to the normal request resolution path.

---

### NT-2 — Auto-borrow completion guard (`newState` check) is untested

**File:** `Palace/MyBooks/DownloadStartDispatcher.swift:164–168`

```swift
let newState = delegate.bookRegistry.state(for: book.identifier)
Log.debug(#file, "Auto-borrow completed for \(book.identifier), new state: \(newState)")
if newState != .downloading && newState != .downloadSuccessful && newState != .downloadNeeded {
    Log.warn(#file, "Auto-borrow completed but book is not downloadable, state: \(newState)")
}
```

**Surviving mutants:**
- Drop any of the three `!=` clauses (e.g. `!= .downloading`) — the warning
  would still log on most paths, but specific transitions (auto-borrow that
  succeeds and lands in `.downloading`) would mis-log "not downloadable."
- Flip `&&` to `||` — would log warning on every successful borrow.

**Coverage gap:** `testProcessRegularDownload_downloadNeededWithBorrowLink_triggersAutoBorrow`
(`DownloadStartDispatcherTests.swift:246–255`) invokes the branch but the
`spyDelegate.startBorrow` implementation doesn't synchronously call
`borrowCompletion`. The closure passed at L162–169 of the production code
is never executed under test. A surviving mutant in that closure would
not fail any current test.

**Suggested fix:** make `SpyDispatcherDelegate.startBorrow` accept a
post-borrow-state hook and invoke `borrowCompletion?()` with the registry
in a desired state, then assert no spurious log/announcement. Even simpler:
extract the post-borrow logging predicate into a small pure helper
(`isDownloadableState(_:) -> Bool`) and test that directly — the predicate
is the part that has F-014 surface.

```swift
// Add to DownloadStartDispatcher:
static func isDownloadableState(_ state: TPPBookState) -> Bool {
    state == .downloading || state == .downloadSuccessful || state == .downloadNeeded
}

// And use at L166:
if !Self.isDownloadableState(newState) { Log.warn(...) }

// Test all 10 enum cases:
func testIsDownloadableState_pinsAllCases() {
    XCTAssertTrue(DownloadStartDispatcher.isDownloadableState(.downloading))
    XCTAssertTrue(DownloadStartDispatcher.isDownloadableState(.downloadSuccessful))
    XCTAssertTrue(DownloadStartDispatcher.isDownloadableState(.downloadNeeded))
    XCTAssertFalse(DownloadStartDispatcher.isDownloadableState(.unregistered))
    XCTAssertFalse(DownloadStartDispatcher.isDownloadableState(.holding))
    XCTAssertFalse(DownloadStartDispatcher.isDownloadableState(.SAMLStarted))
    XCTAssertFalse(DownloadStartDispatcher.isDownloadableState(.downloadFailed))
    XCTAssertFalse(DownloadStartDispatcher.isDownloadableState(.used))
    XCTAssertFalse(DownloadStartDispatcher.isDownloadableState(.returning))
    XCTAssertFalse(DownloadStartDispatcher.isDownloadableState(.unsupported))
}
```

---

### NT-3 — `isWifiOnlyEnforced` only verified on one branch

**File:** `Palace/MyBooks/DownloadStartDispatcher.swift:61–63, 173–176`

```swift
private var isWifiOnlyEnforced: Bool {
    settings.downloadOnlyOnWiFi && !isOnWiFi()
}
```

**Surviving mutants:**
- Flip `&&` to `||` — would block downloads whenever `downloadOnlyOnWiFi`
  is on OR off-Wi-Fi, broadly breaking download on cellular even with the
  toggle off.
- Drop the `!` from `!isOnWiFi()` — would invert: blocks ON Wi-Fi.

**Coverage gap:** existing `testProcessRegularDownload_wifiOnlyEnforced_failsAndDoesNotStartDownload`
(L193–204) sets both flags true (toggle on, off Wi-Fi). It does not cover:
- toggle on, ON Wi-Fi (must proceed)
- toggle off, off Wi-Fi (must proceed)

**Suggested fix:**

```swift
func testProcessRegularDownload_wifiOnly_onWiFi_proceedsWithDownload() {
    settings.downloadOnlyOnWiFi = true
    isOnWiFiValue = true
    let book = openAccessBook()
    registry.addBook(book, ...)

    dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

    XCTAssertTrue(spyDelegate.failWithWifiCalls.isEmpty)
    XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
}

func testProcessRegularDownload_wifiOff_offWiFi_proceedsWithDownload() {
    settings.downloadOnlyOnWiFi = false
    isOnWiFiValue = false
    let book = openAccessBook()
    registry.addBook(book, ...)

    dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

    XCTAssertTrue(spyDelegate.failWithWifiCalls.isEmpty)
    XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
}
```

---

### NT-4 — `processDownloadWithCredentials` non-borrow states (`.downloading`, `.downloadFailed`, `.SAMLStarted`, `.downloadNeeded`, `.downloadSuccessful`, `.used`, `.returning`, `.unsupported`) are untested for the fall-through

**File:** `Palace/MyBooks/DownloadStartDispatcher.swift:121–135`

```swift
if state == .unregistered || state == .holding {
    delegate.startBorrow(...)
    return
}
... overdrive branch ...
processRegularDownload(for: book, withState: state, andRequest: initedRequest)
```

**Surviving mutants:**
- Flip `||` to `&&` — `state == .unregistered && state == .holding` is
  always false, so EVERY call would skip the borrow branch and fall to
  `processRegularDownload`. The only test that pins the borrow branch is
  for `.unregistered` (L172) and `.holding` (L182); for each of those a
  fall-through would manifest as no `startBorrow` call PLUS a download
  attempt — but the tests only assert "1 startBorrow call." If the mutant
  ALSO produced `addDownloadTask` calls, the existing tests wouldn't
  notice (`spyDelegate.addDownloadTaskCalls` is not asserted empty in
  the borrow tests).
- Drop `state == .unregistered` — `.unregistered` falls through to
  processRegularDownload, which queries the registry, finds no book,
  and calls `logInvalidURLRequest`. Existing test would still pass:
  `startBorrowCalls.count == 1` becomes 0, that part fires, but no
  other test catches that downstream side effect.

**Coverage gap:**
- `testProcessDownloadWithCredentials_unregistered_routesToStartBorrow` (L172)
  does not assert `spyDelegate.addDownloadTaskCalls.isEmpty` until the very
  last line — but actually it DOES, line 179. Good. Same for `.holding`
  test? Line 187 only checks borrow count; line 188 checks first
  identifier. **No `addDownloadTaskCalls.isEmpty` assertion for the
  `.holding` branch.** That's the gap.

**Suggested fix:** Add `XCTAssertTrue(spyDelegate.addDownloadTaskCalls.isEmpty)`
to `testProcessDownloadWithCredentials_holding_routesToStartBorrow` (L182).
Then add a parametrized test that runs every non-borrow, non-Overdrive
state through `processDownloadWithCredentials` and asserts it routes to
`addDownloadTask` (or `failWithWifi` / `logInvalid` as appropriate),
NEVER to `startBorrow`:

```swift
func testProcessDownloadWithCredentials_nonBorrowStates_doNotStartBorrow() {
    let nonBorrowStates: [TPPBookState] = [
        .downloading, .downloadFailed, .downloadSuccessful,
        .downloadNeeded, .used, .returning, .unsupported, .SAMLStarted
    ]
    for state in nonBorrowStates {
        let book = openAccessBook() // no borrow link → no auto-borrow
        registry.addBook(book, location: nil, state: state, fulfillmentId: nil,
                         readiumBookmarks: nil, genericBookmarks: nil)
        spyDelegate.reset()

        dispatcher.processDownloadWithCredentials(for: book, withState: state, andRequest: nil)

        XCTAssertEqual(spyDelegate.startBorrowCalls.count, 0,
                       "State \(state): must NOT call startBorrow")
    }
}
```

This is the canonical "exhaustive switch substitute" pattern referenced in
CLAUDE.md TDD section.

---

### NT-5 — Auto-borrow branch resets registry to `.unregistered` (untested)

**File:** `Palace/MyBooks/DownloadStartDispatcher.swift:159–171`

```swift
if state == .downloadNeeded && currentBook.defaultAcquisitionIfBorrow != nil {
    ...
    delegate.bookRegistry.setState(.unregistered, for: book.identifier)   // ← L161
    delegate.startBorrow(for: currentBook, attemptDownload: true) { ... }
    return
}
```

**Surviving mutants:**
- Change `.unregistered` to `.downloadNeeded` (no-op self-write) — auto-borrow
  would still trigger, but the registry would not reflect the
  in-progress-borrow state. Tests would still pass.
- Drop the `setState` call entirely.

**Coverage gap:** `testProcessRegularDownload_downloadNeededWithBorrowLink_triggersAutoBorrow`
(L246) asserts `startBorrowCalls.count == 1` and addDownloadTask empty,
but does NOT inspect the registry post-call. A mutant that drops the
`setState(.unregistered, ...)` survives.

**Suggested fix:** add `XCTAssertEqual(registry.state(for: book.identifier), .unregistered)`
after the dispatcher call. Same applies to NT-1 (expired re-borrow) — both
auto-borrow paths reset registry state and that is a load-bearing side
effect (the next sync depends on it).

---

### NT-6 — SAML branch missing-cookies fallthrough untested

**File:** `Palace/MyBooks/DownloadStartDispatcher.swift:200–211`

```swift
if state == .SAMLStarted, let cookies = userAccount.cookies {
    Log.info(#file, "SAML authentication flow for '\(currentBook.title)'")
    delegate.handleSAMLStartedState(for: currentBook, withRequest: request, cookies: cookies)
} else {
    ...
    delegate.clearAndSetCookies()
    delegate.addDownloadTask(with: request, book: currentBook)
}
```

**Surviving mutants:**
- Flip `state == .SAMLStarted` to `state != .SAMLStarted` — every non-SAML
  call would attempt SAML handling, but the `let cookies = userAccount.cookies`
  guard would short-circuit on the common case (no cookies). On the SAML
  branch the cookies-present path would route to the else clause —
  inverting SAML handling entirely.
- Flip `.SAMLStarted` to another case (e.g. `.downloading`) — SAML
  downloads would never use the SAML branch.

**Coverage gap:** `testProcessRegularDownload_samlState_routesThroughSAMLHandler`
(L234–244) covers the happy path: `.SAMLStarted` state + cookies present.
**Missing:** `.SAMLStarted` state with NO cookies (must fall through to
`addDownloadTask`); non-SAML state with cookies present (must NOT route
to SAML handler).

**Suggested fix:**

```swift
func testProcessRegularDownload_samlStateNoCookies_fallsThroughToAddDownloadTask() {
    let book = openAccessBook()
    registry.addBook(book, location: nil, state: .SAMLStarted, ...)
    userAccount.setCookies(nil)   // explicitly no cookies

    dispatcher.processRegularDownload(for: book, withState: .SAMLStarted, andRequest: nil)

    XCTAssertTrue(spyDelegate.samlHandlerCalls.isEmpty,
                  "SAMLStarted without cookies must NOT enter SAML handler")
    XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
}

func testProcessRegularDownload_nonSamlStateWithCookies_doesNotRouteToSAMLHandler() {
    let book = openAccessBook()
    registry.addBook(book, location: nil, state: .downloadNeeded, ...)
    userAccount.setCookies([HTTPCookie(properties: [.name: "S", .value: "x",
                                                     .domain: "e.com", .path: "/"])!])

    dispatcher.processRegularDownload(for: book, withState: .downloadSuccessful, andRequest: nil)

    XCTAssertTrue(spyDelegate.samlHandlerCalls.isEmpty)
    XCTAssertEqual(spyDelegate.addDownloadTaskCalls.count, 1)
}
```

---

## CLEAN findings (1)

### CL-1 — F-011 (missing enum case) is impossible by construction

**File:** `Palace/MyBooks/DownloadStartDispatcher.swift` (whole file)

The dispatcher has **zero `switch` statements** on `TPPBookState` (or any
enum). All state-machine decisions use `if state == .X` / `if state == .X ||
state == .Y` comparisons. F-011 requires a `switch` with `default:` falling
through silently for a case it should have named explicitly; the pattern
cannot occur here.

(For comparison, the F-011 site in `BookButtonMapper` IS a switch — this
file does not have the precondition for that defect class.)

### F-017 not applicable

Dispatcher publishes nothing. `final class DownloadStartDispatcher { weak
var delegate; private let ...; }` — no `@Published` properties, no
`PassthroughSubject`, no `CurrentValueSubject`, no Combine pipeline at all.
F-017 (missing state observation in a `@Published` reducer) does not have
a target surface.

---

## Mutation-testing notes

A diff-only mutation run pinned to this file's changed lines vs. 3.0.2
would surface the 13+ mutants enumerated above. The current test file
would survive ~6 of them, putting the file in the "below 50% kill rate"
band when measured strictly. Recommend:

```bash
python3 scripts/palace_mutate.py \
  --file Palace/MyBooks/DownloadStartDispatcher.swift \
  --tests PalaceTests/MyBooks/DownloadStartDispatcherTests \
  --diff-only --diff-base 3.0.2
```

after adding the NT-1 / NT-3 / NT-4 / NT-5 / NT-6 tests above (NT-2 is a
production-side refactor + test).

Critical-path note: `Palace/MyBooks/Download*` is in the strict-mutation
allowlist per CLAUDE.md ("Default mode keeps strict-only on critical
paths: `Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`").
So the 50% gate is enforced for this file under
`verify-pr.sh --quick` already. The NEEDS-TEST gaps above are real CI
risk for the next PR that touches this file.

---

## Headline

**No bug present.** The Phase 7 extraction of `DownloadStartDispatcher`
preserved 3.0.2 logic faithfully and F-011 / F-017 are impossible by
construction. The most important issue is **NT-4**: the
`processDownloadWithCredentials` borrow-routing branch is only pinned for
2 of the 10 `TPPBookState` cases — a parametrized "non-borrow states never
call startBorrow" test is the highest-leverage addition.
