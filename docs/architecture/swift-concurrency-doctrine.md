# Swift concurrency doctrine

<!-- audit-verified -->

How to resolve a concurrency diagnostic in this repo. Lifted from the Swift 6
modernization plans when those were retired — the migration finished at PR
**#1199** (`SWIFT_VERSION 5.0 → 6.0`), and the project now builds at
`SWIFT_VERSION = 6.0` with `SWIFT_STRICT_CONCURRENCY = complete` on every
config, so a violation is a compile **error**, not a warning.

The plans were exhaust once that landed. This is the part that wasn't: the
rules were paid for across 10+ merged PRs and they apply to code written now.

## Fix by ISOLATION, never `nonisolated(unsafe)`

The #1129 playbook, in the order to try:

| diagnostic | fix |
|---|---|
| value type not `Sendable` | add `: Sendable` — additive, no behaviour change |
| generic `T` crossing a `Task`/continuation | constrain it: `<T: Sendable>` |
| class captured or crossed | `final class … : @unchecked Sendable` **with a documented invariant** — lock-guarded, or immutable-after-init. **No bare `@unchecked`.** |
| `@MainActor` member reached from nonisolated | `await MainActor.run { }`, or mark the member `@MainActor` |
| delegate conformance "crosses into main actor-isolated code" | `@preconcurrency` on the *conformance* (the EmailTicketGateway #1134 pattern), **only if every caller is on the main thread**. The relaxed conformance still traps at runtime when a witness runs off main. If a requirement can be called off main (for example from a URLSession delegate queue), use a `nonisolated` witness over lock-guarded state instead (PP-5465) <!-- audit-verified --> |
| a module's types not Sendable-audited | `@preconcurrency import <Module>` |

**`nonisolated(unsafe)` is not on this list.** It silences the compiler without
establishing the invariant, so the next reader cannot tell a checked case from
an unchecked one. Do not use it to fix a new diagnostic. The uses that remain
are listed under [Retained exceptions](#retained-exceptions); a new one belongs
in one of those groups, with a comment at the declaration that states its rule.

**Avoid `MainActor.assumeIsolated` in `deinit`** — it `fatalError`s when the
object is released off-main, which is exactly when a deinit is hardest to
predict. The same trap applies to any completion handler that asserts main-actor
isolation and is then called from a background queue.

## Retained exceptions

Each group below relaxes the compiler's check on purpose. The rule is what keeps
it safe; the owner is the code that must keep the rule true, and the reviewer of
a change to that code checks it. No CI check counts these uses. Census on
`develop`: `git grep -n 'nonisolated(unsafe)' -- Palace` (23 declarations
outside comments) and `git grep -n '@preconcurrency' -- Palace`.

| Group | Sites | Rule that keeps it safe | Owner |
|---|---|---|---|
| Test seams on static APIs | `TPPAnnotations` and `AnnotationDevice` overrides (`Palace/Reader2/Bookmarks/TPPAnnotations.swift`), `RemoteFeatureFlags.oidcStubDefaults` (`Palace/FeatureFlags/RemoteFeatureFlags.swift`, `#if DEBUG`) | `nil` or the default in production. Tests set them in `setUp`, before the code under test runs, and clear them in `tearDown`. Production code never writes them. | The test class that sets the override; the owning type for any new seam |
| Composition-root providers | `TPPBookImageContext.imageCacheProvider` / `imageLoaderProvider` (`Palace/Packages/PalaceBookModel`) | Written once by `AppContainer` (`Palace/AppInfrastructure/AppContainer.swift:551`) during launch, before any reader; cleared only by `_resetForTesting()`. | `AppContainer` |
| Combine subjects held by an actor | `AccessibilityService`, `OfflineQueueService`, `PerformanceMonitor` (`Palace/Platform/`), `PositionSyncService` (`Palace/Packages/PalaceReadingPosition`) | The subject is a `let` set in `init` and never replaced. Subscribers attach through a `nonisolated` `AnyPublisher` so they need not await the actor. This depends on Combine subjects locking internally, which Apple does not document as `Sendable`. | The actor that declares the subject |
| Lock-guarded or thread-safe storage | `CancellableContinuationBox.pendingResult` (`Palace/Network/TPPNetworkExecutor.swift`), `SafeDictionary._syncMirror` (`Palace/Packages/PalaceUtilities`) and `TPPAnnotations._lastDeletionChain` | Every read and write holds the type's lock (`NSLock`). | The declaring type; a new access path must take the same lock |
| Write-once, read-in-`deinit` | `TPPBookCoverRegistry.reachabilityObserverToken` | Written once in `init`, read once in the nonisolated `deinit`, when no other reference exists. | `TPPBookCoverRegistry` |
| Local captures across one hop | `AudiobookPositionTraceRecorder` (`UserDefaults`), `NowPlayingCoordinator` (artwork `UIImage`), `TPPSignInBusinessLogic` (`Result` handed to the main actor) | The captured value is immutable after capture and only read on the other side of the hop; the comment at each site names the type's thread-safety basis. | The enclosing function |
| `@preconcurrency import` | Readium modules, `PalaceAudiobookToolkit`, `AVFoundation`, `PDFKit`, `WebKit`, Firebase, `SQLite`, `PalaceAuth`, `PalaceCatalog` and others | The module's types are not yet `Sendable`-audited. Values from it stay on the actor that received them; do not send them across isolation boundaries on the strength of the import. Remove the attribute when the module ships `Sendable` annotations. | The Palace file that imports the module |
| `@preconcurrency` conformances | delegate conformances such as `EmailTicketGateway` (#1134) | Every caller of the witness is on the main thread. A requirement that can be called off main uses a `nonisolated` witness over lock-guarded state instead (PP-5465). | The conforming type |

## Two things that ripple further than they look

**Making a PROTOCOL `Sendable` reaches every conformer**, including test mocks.
Budget for the conformers before changing the protocol, not after the build
breaks.

**Shared types cascade, so map them first.** Concurrency diagnostics are not
independent: fixing one shared type clears several sites at once, and fixing
sites individually does the same work repeatedly. The retired A.5 plan found 31
warnings that collapsed to a handful of root types — `AccountDetails`,
`AccountsManager`, `TPPUserAccountProvider`. Enumerate the shared types in the
diagnostic set before writing any fix.

A corollary that plan stated and is worth keeping: **do not blindly `@unchecked`
a large shared type.** Check its mutable state first. A type that is big enough
to be tempting is big enough to hide a real race.

## Measuring

Under `complete` + language mode 6.0 the count is structurally zero — the build
fails otherwise. If a measurement is ever needed against a looser setting, take
it from a CI build log rather than a local `xcodebuild` override: a *global*
`SWIFT_STRICT_CONCURRENCY` override also overrides the SPM packages' own v6
mode and re-flags already-`Sendable` package types, over-counting. Per-target
settings only.
