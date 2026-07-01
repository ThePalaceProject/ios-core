# Transcript — OPDS-PDF-Catalog (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2. Fix by ISOLATION only. No behavior changes.
All four in-scope files edited; nothing off-scope touched.

---

## Site 1 — `Palace/OPDS/TPPOPDSFeed+Networking.swift`

**Symbol:** `TPPOPDSFeed.withURL(_:shouldResetCache:useTokenIfAvailable:completionHandler:)`,
the `networkExecutor.GET` completion body, two `TPPAsyncDispatch { handler(nil, …) }` sites.

**Warning:** `capture of 'errorDict' (NSDictionary?)` in the `@Sendable`
`TPPAsyncDispatch` closure at:
- HTTP-status branch (`errorDict = problemDocDict ?? synthesized-from-status`)
- XML-parse-fail branch (`errorDict = try? JSONSerialization… as? NSDictionary`)

**Fix (isolation):** introduced ONE `private struct` carrier at file scope,
`SendableOPDSErrorDictionary: @unchecked Sendable { let value: NSDictionary? }`.
At each site the dict is boxed on the calling thread (`let errorBox =
SendableOPDSErrorDictionary(value: errorDict)`) and the closure captures the
Sendable box, forwarding `handler(nil, errorBox.value)`. `handler(nil, …)`
argument shape and the `return` early-exits are unchanged.

**Mirrored pattern:** `SendableErrorDocument` at the bottom of
`Palace/Book/Models/BookRegistrySync.swift`. Invariant is identical: the
dictionary is built once from a caught error / HTTP response and only ever read
thereafter (forwarded to `handler`), so moving it across the dispatch boundary
is race-free.

**Behavior risk:** none. Same dictionary value forwarded to the same handler on
the same `TPPAsyncDispatch` hop. The other `TPPAsyncDispatch` sites in the
function (`handler(nil, nil)`, `handler(feed, nil)`) were not flagged by the A.4
snapshot and were left untouched.

---

## Site 2 — `Palace/PDF/Views/PDFThumbnailStrip.swift`

**Symbol:** `PDFThumbnailStripCell.Fetcher.fetch()` (`@MainActor final class Fetcher`).

**Warning:** `capture of 'provider' (PDFKitThumbnailProvider)` in the `@Sendable`
`DispatchQueue.pdfThumbnailRenderingQueue.async { … provider.thumbnail(for: page) … }`
closure.

**Fix (isolation):** added a `private final class ThumbnailProviderBox:
@unchecked Sendable` (file scope) wrapping the provider. `fetch()` boxes the
provider on the main actor (`let providerBox = ThumbnailProviderBox(self.provider)`)
and the background-queue closure captures the box, calling
`providerBox.provider.thumbnail(for: page)`. The `guard image == nil`
short-circuit, the `guard let rendered else { return }`, and the
`DispatchQueue.main.async { [weak self] in self?.image = rendered }` main hop are
all preserved verbatim.

**Mirrored pattern:** `ImageCompletionBox` (`private final class … @unchecked
Sendable`) in `Palace/Utilities/ImageCache/ImageLoaderImpl.swift`. Invariant:
`thumbnail(for:)` is invoked only on `pdfThumbnailRenderingQueue` and the result
is published back on main; the provider is never touched concurrently. Chose the
carrier box (the contract's safe default) rather than making
`PDFKitThumbnailProvider` itself `Sendable` — did NOT touch its internals.

**Behavior risk:** none. Same provider, same render queue, same main-hop publish.

---

## Site 3 — `Palace/CatalogUI/ViewModels/CatalogViewModel.swift`

**Symbol:** `CatalogViewModel.load()` (`@MainActor final class`), the inactive
entry-point preload `Task.detached(priority: .utility)` → `group.addTask`.

**Warning:** `main actor-isolated property 'repository' can not be referenced
from a non-isolated context` — the detached preload read `self.repository`
(main-actor-isolated `CatalogRepositoryProtocol`) off the main actor inside
`group.addTask`.

**Fix (isolation) — two parts, per contract:**
1. Hoisted the read onto the main actor: bound `let repository = self.repository`
   BEFORE `Task.detached(...)`, and the `group.addTask` body now calls
   `repository.loadTopLevelCatalog(at: epURL)` on the captured local Sendable
   value. Because the detached closure no longer references `self` at all, the
   `[weak self] in / guard let self else { return }` prologue was removed — this
   is behavior-equivalent: the task is appended to `prefetchTasks`, which
   `deinit` cancels on teardown, and each fetch is already guarded by
   `Task.isCancelled`, so the preload still short-circuits when the VM goes away.
   Priority (`.utility`) and off-main execution context are unchanged.
2. Protocol Sendable — see Site 4.

**Mirrored pattern:** value-hoist-before-detached (capture a Sendable local
instead of reading a main-actor property off-actor), the same shape used by the
existing `Task.detached { [bookRegistry = self.bookRegistry] … }` at the top of
`load()`.

**Behavior risk:** none. Only line 229's off-main property read was flagged
(A.4 snapshot); the `currentLoadTask = Task { … }` at line 138 inherits the
MainActor context and was not touched.

---

## Site 4 — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift`

**Symbol:** `public protocol CatalogRepositoryProtocol` (line 8).

**Change:** `public protocol CatalogRepositoryProtocol: Sendable`.

**Conformer evidence (package won't break):** the sole conformer in the package,
`public final class CatalogRepository` (line 22), is **already declared
`@unchecked Sendable`** with a documented concurrency invariant (all mutable
state behind an `OSAllocatedUnfairLock`; remaining stored properties are
immutable `let`s / `@Sendable` closures). The protocol is a stateless service of
async methods + synchronous cache lookups — no stored state — so requiring
`Sendable` adds no obligation the conformer doesn't already satisfy, and ripples
nothing onto closures. Verified there are no other conformers of
`CatalogRepositoryProtocol` inside the PalaceCatalog package. This edit is the
cascade that clears CatalogViewModel:229 (the hoisted local is now a Sendable
value).

**Behavior risk:** none — a protocol marker constraint, no runtime change.

---

## Scope confirmation

Touched ONLY these 4 files:
- `Palace/OPDS/TPPOPDSFeed+Networking.swift`
- `Palace/PDF/Views/PDFThumbnailStrip.swift`
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift`
- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift`

No `nonisolated(unsafe)`. No bare `@unchecked Sendable` — both new carriers carry
a documented write-once/queue-confined invariant. No behavior changes. Per
contract: no verify-pr / palace_mutate / xcresult / build run (no DRM build in
this worktree).
