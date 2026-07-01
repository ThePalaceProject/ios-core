# Swift 6 `targeted` sweep — Group C transcript

Phase A.6, isolation-only. No behavior change. Test-target files only.

## Summary

6 warnings across 5 files fixed. No production (`Palace/...`) edits. No STOP.

Two of the six warnings ("conformance crosses into main actor") did NOT match
the worklist's default fix pattern #2 ("mark the class `@MainActor`"): the
conforming classes were **already** `@MainActor`, and the *protocols* are
nonisolated (`CatalogRepositoryProtocol: Sendable`, `EPUBSearchDelegate:
AnyObject`). So `@MainActor` on the class was the *cause*, not the fix. The
correct isolation-only fix for a `@MainActor` type conforming to a nonisolated
protocol is to make the offending witnesses nonisolated (and, where they touch
state, thread-safe via a documented lock). Details per file below.

---

## 1. PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift

**Warning (worklist #7, line 20:36):** conformance of `CatalogRepositoryMock`
to `CatalogRepositoryProtocol` crosses into main actor-isolated code.

**Root cause:** `CatalogRepositoryMock` is `@MainActor`; production
`CatalogRepositoryProtocol` is `public protocol ...: Sendable` (nonisolated).
The protocol's `async` requirements are fine — a `@MainActor` async method
witnesses a nonisolated async requirement (caller hops). The two **synchronous**
requirements (`invalidateCache(for:)`, `cachedFeed(for:)`) cannot be witnessed
by main-actor-isolated methods → the crossing.

**Fix:** marked those two witnesses `nonisolated`. Both are stateless in the
mock (`invalidateCache` is a no-op; `cachedFeed` returns `nil`), so `nonisolated`
is sound and touches no `@MainActor` state. Class stays `@MainActor` for all its
stateful async methods. Behavior unchanged.

---

## 2. PalaceTests/Reader2/EPUBSearchViewModelTests.swift

**Warning (worklist #36, line 100:37):** conformance of `MockEPUBSearchDelegate`
to `EPUBSearchDelegate` crosses into main actor-isolated code.

**Root cause:** `MockEPUBSearchDelegate` is `@MainActor`; production
`EPUBSearchDelegate` (`Palace/Reader2/UI/EpubSearchView/EPUBSearchViewModel.swift:13`)
is a nonisolated `AnyObject` protocol whose sole requirement
`func didSelect(location: Locator)` is **synchronous**. A main-actor witness of
a synchronous nonisolated requirement is the crossing. Unlike case #1, this
witness *mutates* state (`didSelectCallCount`, `lastSelectedLocation`), so a bare
`nonisolated` witness would be unsafe.

**Fix:** removed `@MainActor`, made the class `@unchecked Sendable`, and guarded
the two counters behind an `NSLock` (documented `@unchecked Sendable` — allowed).
`didSelect(location:)` is now a thread-safe nonisolated witness. The public
read surface (`didSelectCallCount`, `lastSelectedLocation`) is preserved as
lock-backed computed properties, so the two assertion sites (lines 328–329, 342)
are unchanged. Observable behavior identical.

---

## 3. PalaceTests/Network/CookiePersistenceTests.swift

**Warning (worklist #35, line 50:21):** `TPPUserAccountCookieMock` must restate
inherited `@unchecked Sendable` conformance.

**Fix:** added `, @unchecked Sendable` to the declaration
(`private final class TPPUserAccountCookieMock: TPPUserAccountMock, @unchecked Sendable`).
Restatement of the inherited conformance — pattern #1. No behavior change.

---

## 4. PalaceTests/SignInLogic/TPPCrossLibrarySignOutTests.swift

**Warning (worklist #37, line 25:15):** `TPPMultiLibraryAccountMock` must
restate inherited `@unchecked Sendable` conformance.

**Fix:** added `, @unchecked Sendable`
(`private class TPPMultiLibraryAccountMock: TPPUserAccountMock, @unchecked Sendable`).
Non-`final` class; `@unchecked Sendable` restatement is valid. No behavior change.

---

## 5. PalaceTests/Integration/SignInToReadFlowIntegrationTests.swift

**Warnings (worklist #8 + #9, both at line 115):**
- `capture of 'self' with non-Sendable type 'SignInToReadFlowIntegrationTests?'
  in a '@Sendable' closure`
- `main actor-isolated property 'readerOpenedBookIds' can not be mutated from a
  Sendable closure`

**Site:** the reader-open observer registered in `setUp()` via
`NotificationCenter.addObserver(forName:object:queue:using:)`. The `using:` block
is `@Sendable`. It captured `[weak self]` and did
`self?.readerOpenedBookIds.append(id)`. Two problems: (a) `self` is
non-Sendable (the class is `@MainActor` but its `XCTestCase` superclass is not,
so no implicit `Sendable`), captured in a `@Sendable` escaping closure; (b) it
mutates a `@MainActor` stored property from that nonisolated closure.

**Which hop I used and why it preserves behavior:** I did **not** use a
`MainActor.assumeIsolated` / `Task { @MainActor in }` / `DispatchQueue.main.async`
hop. A hop clears warning #9 (the mutation) but **not** #8: the `@Sendable`
closure would still capture non-Sendable `self` regardless of what happens
inside it, because the escaping `@Sendable` block requires its captures to be
Sendable. A `Task`/DispatchQueue hop would also defer the append, changing
timing/order relative to the existing assertions.

Instead I introduced a small `private final class ReaderOpenRecorder:
@unchecked Sendable` (NSLock-guarded `[String]`) and changed
`readerOpenedBookIds` from a `@MainActor var [String]` to a `let` recorder. The
observer block now captures `[recorder = readerOpenedBookIds]` (a `Sendable`
reference) instead of `self`, and calls `recorder.append(id)`:
- Warning #8 gone: no `self` (or any non-Sendable value) captured — only
  `recorder` (Sendable) and `id` (`String`, Sendable).
- Warning #9 gone: the mutation now targets a `Sendable` type's own method, not
  a `@MainActor` stored property.
- Behavior preserved: `append` stays **synchronous** on the notification's
  `.main`-queue delivery (no actor hop → ordering/timing unchanged). The two
  read sites are unchanged in meaning:
  `self?.readerOpenedBookIds.contains(book.identifier) ?? false` (waitUntil) and
  `readerOpenedBookIds.contains(book.identifier)` (XCTAssertTrue) now call the
  recorder's `contains(_:)`, returning the same `Bool`. `readerOpenedBookIds = []`
  in `setUp()` became `readerOpenedBookIds.reset()`.

No STOP. A `MainActor.assumeIsolated`-only fix would have left #8 unresolved; the
recorder is the clean, behavior-preserving isolation fix (documented
`@unchecked Sendable`, allowed).

---

## Confirmation

- Files edited (Group C only): CatalogSearchViewModelTests.swift,
  EPUBSearchViewModelTests.swift, CookiePersistenceTests.swift,
  TPPCrossLibrarySignOutTests.swift, SignInToReadFlowIntegrationTests.swift.
- No `Palace/...` production files edited.
- Never used `nonisolated(unsafe)`. Only `nonisolated` witnesses and documented
  `@unchecked Sendable`.
- Did not build / run tests / run verify-pr per instructions.
