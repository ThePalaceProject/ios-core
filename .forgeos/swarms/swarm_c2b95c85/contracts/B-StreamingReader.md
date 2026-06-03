# Module B — Streaming Reader (new in-app reader module)

**Standard risk.** All NEW files in a NEW directory (`Palace/ReaderStreaming/`).
No existing file modifications other than pbxproj additions + small additive
edits to `Strings.swift` and `AccessibilityIdentifiers.swift` shared
namespaces (Module C also edits those — coordination via section-level edits,
no overlapping symbols).

## Goal

Build the new `Palace/ReaderStreaming/` module: a thin WKWebView shell with
Close + scroll only, plus a protocol-fronted UserDefaults progress store and
a SwiftUI `UIViewControllerRepresentable` wrapper for presentation parity
with Reader2 / Reader3. No JS bridge, no annotation layer, no TOC / font /
theme / print / share controls (per intent anti-claims). Online-only — render
a "Connection required" state when offline.

## What public types/protocols change

NEW (all in `Palace/ReaderStreaming/`):

- `StreamingReaderViewController: UIViewController` — UIKit shell.
  - `init(viewModel: StreamingReaderViewModel)`
  - Hosts a `WKWebView`, a Close `UIBarButtonItem`, optional swipe-down dismiss.
  - Calls `viewModel.didDismiss()` (which triggers progress save) on `viewDidDisappear`.

- `StreamingReaderViewModel: ObservableObject, @MainActor` — owns URL + store + bookID.
  - `init(book: TPPBook, store: StreamingReaderProgressStoring, reachability: ReachabilityProviding = ReachabilityManager.shared, urlSession: URLSession = .shared)`
  - `@Published var state: StreamingReaderState` where
    `enum StreamingReaderState { case loading, ready(URL, restoredScroll: CGFloat?), offline, failed(Error) }`
  - `func didNavigationFinish(scrollOffset: CGFloat)` — called by VC on `webView.scrollView` notifications.
  - `func didDismiss()` — saves progress synchronously to the store, fires close.
  - `func reload()` — for the offline retry button.

- `StreamingReaderProgressStoring: AnyObject` (protocol):
  - `func save(scrollOffset: CGFloat, fragment: String?, forBookID bookID: String)`
  - `func read(forBookID bookID: String) -> StreamingReaderProgress?`
  - `struct StreamingReaderProgress { let scrollOffset: CGFloat; let fragment: String? }`

- `StreamingReaderProgressStore: StreamingReaderProgressStoring` — UserDefaults-
  backed default. Key prefix `palace.streamingReader.progress.<bookID>`. JSON-
  encoded payload. Malformed JSON returns nil (caller treats as "no saved progress").
  - `init(userDefaults: UserDefaults = .standard)`

- `StreamingReaderView: View` (SwiftUI `UIViewControllerRepresentable`):
  - `init(book: TPPBook, store: StreamingReaderProgressStoring = StreamingReaderProgressStore())`
  - Wraps `StreamingReaderViewController` for SwiftUI presentation.

## What internal seams (DI) need updating

- `ReachabilityProviding` protocol — if one doesn't already exist for the
  reachability check, introduce a minimal one in this module
  (`Palace/ReaderStreaming/Reachability+StreamingReader.swift`) that
  `ReachabilityManager.shared` conforms to via an extension. Test injects a
  `FakeReachability` returning a configurable `Bool`.
- `StreamingReaderProgressStoring` protocol (above) — tests use
  `FakeStreamingReaderProgressStore: StreamingReaderProgressStoring` in
  `PalaceTests/ReaderStreaming/Mocks/`.

## Test contracts the module must satisfy

1. **Progress save on dismiss (mandatory).**
   `testStreamingReaderViewModel_didDismiss_persistsScrollOffsetToStore`.
   Construct with a `FakeStreamingReaderProgressStore`, call
   `didNavigationFinish(scrollOffset: 250)` then `didDismiss()`, assert the
   fake recorded a `save(scrollOffset: 250, fragment: _, forBookID: book.identifier)`.

2. **Progress restore on open (mandatory).**
   `testStreamingReaderViewModel_init_withSavedProgress_emitsReadyStateWithRestoredOffset`.
   Pre-seed the fake store with `(250, nil)` for the book, construct VM,
   await state transition to `.ready(_, restoredScroll: 250)`.

3. **Malformed saved state safe handling (mandatory).**
   `testStreamingReaderProgressStore_read_malformedJSON_returnsNil`.
   Write garbage to UserDefaults under the prefix key, assert
   `store.read(forBookID:)` returns nil (NOT crash, NOT throw).

4. **Round-trip write/read (mandatory).**
   `testStreamingReaderProgressStore_writeThenRead_returnsExactScrollOffset`.
   Use an in-memory `UserDefaults(suiteName:)`, save (123.5, "#section-3"),
   read, assert exact match.

5. **Prefix-scoping (mandatory).**
   `testStreamingReaderProgressStore_read_returnsNilForDifferentBookID`.
   Write for bookA, read for bookB, assert nil.

6. **Offline state (mandatory).**
   `testStreamingReaderViewModel_init_whenOffline_emitsOfflineState`.
   Construct with a `FakeReachability` returning false, await state
   transition to `.offline`. Verify NO network request was made (URL
   should not be loaded into the web view).

7. **State-machine round-trip (per CLAUDE.md "State-machine wiring tests").**
   `testStreamingReaderViewModel_loadingThenReadyThenDismissed_persistsLastOffset`.
   Drive `loading → ready → didNavigationFinish(scrollOffset: X) → didDismiss`
   and assert the saved offset matches.

## Files scoped to THIS implementer

Production (all NEW):
- `Palace/ReaderStreaming/StreamingReaderViewController.swift`
- `Palace/ReaderStreaming/StreamingReaderViewModel.swift`
- `Palace/ReaderStreaming/StreamingReaderProgressStore.swift`
- `Palace/ReaderStreaming/StreamingReaderView.swift`
- (optional) `Palace/ReaderStreaming/Reachability+StreamingReader.swift` — if a `ReachabilityProviding` protocol seam is needed

Shared (additive only — coordinate with Module C section-level edits):
- `Palace/Utilities/Localization/Strings.swift` — add NEW `Strings.StreamingReader` namespace ONLY (close, connectionRequired, retry, loadError). Do not edit any other namespace.
- `Palace/Utilities/Testing/AccessibilityIdentifiers.swift` — add NEW `AccessibilityID.StreamingReader` namespace (closeButton, webView, errorContainer, retryButton).

Project file:
- `Palace.xcodeproj/project.pbxproj` — added EXCLUSIVELY via `ruby scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM --group "Palace/ReaderStreaming" <files>`. No hand-editing. New `ReaderStreaming` group at the same level as `Reader2` / `Reader3`.

Tests (all NEW):
- `PalaceTests/ReaderStreaming/StreamingReaderViewModelTests.swift`
- `PalaceTests/ReaderStreaming/StreamingReaderProgressStoreTests.swift`
- `PalaceTests/ReaderStreaming/Mocks/FakeStreamingReaderProgressStore.swift`
- (optional) `PalaceTests/ReaderStreaming/Mocks/FakeReachability.swift` — only if reachability protocol is introduced

## Files explicitly OFF-LIMITS

- ALL existing files except shared `Strings.swift` + `AccessibilityIdentifiers.swift` additive namespace edits
- `Palace/MyBooks/` — Module C
- `Palace/Book/UI/BookDetail/` — Module C
- `Palace/Reader2/`, `Palace/Reader3/` — explicit anti-claim
- All anti-scope files per `dont_touch` in manifest.yaml

**Coordination note for `Strings.swift` + `AccessibilityIdentifiers.swift`:**
Module B adds the `StreamingReader` sub-namespace. Module C adds `BookButton.readStreaming`
and `BookDetail.readStreamingButton`. These are non-overlapping additions in
DIFFERENT namespaces — git will merge cleanly. If a conflict surfaces during
integration, Module B's additions take precedence (Module B lands first in
wave 1, Module C rebases on B's commits).

## Verification criteria (MANDATORY — grep-able assertions)

1. **All 4 new production files exist:**
   ```bash
   for f in StreamingReaderViewController StreamingReaderViewModel StreamingReaderProgressStore StreamingReaderView; do \
     test -f Palace/ReaderStreaming/$f.swift && echo "$f OK" || echo "$f MISSING"; \
   done
   ```
   All four print "OK".

2. **pbxproj has 8 PBXBuildFile entries for the new sources (4 files × 2 targets):**
   ```bash
   grep -c 'StreamingReaderViewController.swift' Palace.xcodeproj/project.pbxproj
   ```
   Returns ≥ 4 (PBXFileReference + 2× PBXBuildFile + 1× PBXGroup membership).
   ```bash
   for f in StreamingReaderViewController StreamingReaderViewModel StreamingReaderProgressStore StreamingReaderView; do \
     count=$(grep -c "$f.swift" Palace.xcodeproj/project.pbxproj); \
     echo "$f: $count entries (expect ≥4)"; \
   done
   ```

3. **SUT instantiation in tests:**
   ```bash
   grep -c 'StreamingReaderViewModel(' PalaceTests/ReaderStreaming/StreamingReaderViewModelTests.swift
   ```
   Must return ≥ 1.
   ```bash
   grep -c 'StreamingReaderProgressStore(' PalaceTests/ReaderStreaming/StreamingReaderProgressStoreTests.swift
   ```
   Must return ≥ 1.

4. **Protocol-fronted store (no direct UserDefaults reads in VM):**
   ```bash
   grep -c 'UserDefaults' Palace/ReaderStreaming/StreamingReaderViewModel.swift
   ```
   Must return 0 (VM uses the protocol, not concrete UserDefaults).

5. **No `.shared` reads in production:**
   ```bash
   grep -nE '\.shared\b' Palace/ReaderStreaming/*.swift | grep -v 'ReachabilityManager.shared' | grep -v '//'
   ```
   Should be empty (or only document `ReachabilityManager.shared` as the default DI injection).

6. **No force unwraps:**
   ```bash
   grep -nE '![ ;)\.]' Palace/ReaderStreaming/*.swift | grep -v '!=' | grep -v '!(' | grep -v '//'
   ```
   Should return empty (or only inside string literals).

7. **No `DispatchQueue.main.asyncAfter` workarounds:**
   ```bash
   grep -c 'asyncAfter' Palace/ReaderStreaming/*.swift
   ```
   Must return 0 (use `Task` + `await` instead, per `feedback_swift_concurrency_over_gcd.md`).

8. **Tests pass:**
   ```bash
   xcodebuild ... -only-testing:PalaceTests/StreamingReaderViewModelTests \
                  -only-testing:PalaceTests/StreamingReaderProgressStoreTests test 2>&1 | grep -E "Test Suite '.*' passed"
   ```
   Each suite passes.

9. **`python3 scripts/check-test-name-vs-body.py`** clean:
   ```bash
   python3 scripts/check-test-name-vs-body.py PalaceTests/ReaderStreaming/StreamingReaderViewModelTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/ReaderStreaming/StreamingReaderProgressStoreTests.swift
   ```
   Both exit 0.

10. **No anti-scope edits:**
    ```bash
    git diff origin/feat/PP-4161-streaming-html-reader --name-only -- 'Palace/MyBooks/' 'Palace/Book/' 'Palace/OPDS' 'Palace/SignInLogic/' 'Palace/Reader2/' 'Palace/Reader3/' 'Palace/Audiobooks/' | grep -v 'Palace/Book/UI/BookDetail/BookButtonMapper.swift'
    ```
    Must return empty (except the allowed Module C scope which Module B should NOT touch).

## Definition of Done evidence

1. TDD evidence — test commit before production commit.
2. `scripts/verify-pr.sh --quick` PASS tail pasted.
3. `check-test-name-vs-body.py` exit 0 for both new test files.
4. `check-contract-reconciliation.py` exit 0.
5. `check-blast-radius.py` exit 0 — new public surface explicitly justified in commit body.
6. Build clean on both targets:
   ```bash
   xcodebuild -project Palace.xcodeproj -scheme Palace ... build
   xcodebuild -project Palace.xcodeproj -scheme Palace-noDRM ... build
   ```
   Tails pasted.

## Implementer prompt

You are Module B implementer for swarm_c2b95c85 (PP-4161). Build the new
`Palace/ReaderStreaming/` reader module from scratch — 4 production .swift
files + 2 test files + Mocks + pbxproj additions via `ruby
scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM --group
"Palace/ReaderStreaming" <files>`. NO hand-editing the pbxproj. Read
`.forgeos/intent/pp-4161-streaming-html-reader.md` Claims section "Streaming
reader (new module)" — that's your scope. Pure additive — no existing
production file edits except additive `Strings.swift` namespace +
`AccessibilityIdentifiers.swift` namespace. Coordinate with Module C on
those two files: you add `Strings.StreamingReader.*` and `AccessibilityID.StreamingReader.*`;
Module C adds `Strings.BookButton.readStreaming` and `AccessibilityID.BookDetail.readStreamingButton`.
Anti-scope: Reader2/, Reader3/, Audiobooks/, SignInLogic/, MyBooks/, Book/UI/,
plus all dont_touch in manifest.yaml. No JS bridge, no annotation layer, no
TOC/font/theme/print/share. Online-only — render an `.offline` state when
unreachable, NEVER attempt to cache the asset. Protocol-fronted progress store
so tests inject a fake. Use `actor`/`async-await` over GCD/closures.
