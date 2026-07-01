# Contract — OPDS-PDF-Catalog (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2. **Fix by ISOLATION only. No behavior
changes.** Line numbers are the A.4 snapshot — **locate by symbol** and verify.

## Files IN scope (yours, exclusively)
- `Palace/OPDS/TPPOPDSFeed+Networking.swift`
- `Palace/PDF/Views/PDFThumbnailStrip.swift`
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift`
- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift`

## OFF-LIMITS
Everything else. Do not modify Accounts / AppInfrastructure / CarPlay / Reader2 /
Book/Models files. Within PalaceCatalog, touch ONLY `CatalogRepository.swift`
(the protocol decl).

## Global rules
- NEVER `nonisolated(unsafe)`. NO **bare** `@unchecked Sendable`. **Documented**
  `@unchecked Sendable` carrier with a stated invariant IS allowed (mirror
  `SendableErrorDocument`, `ImageCompletionBox`).
- Do NOT run verify-pr / palace_mutate / xcresult (no DRM build).

---

## Site 1 — `TPPOPDSFeed+Networking.swift` ~164 and ~195: capture of `errorDict`
**Warning:** `capture of 'errorDict' (NSDictionary?)` — both call sites do
`TPPAsyncDispatch { handler(nil, errorDict) }` (a `@Sendable` dispatch closure)
capturing a non-Sendable `NSDictionary?`. At ~164 the dict is synthesized from
the HTTP status; at ~195 it is `try? JSONSerialization.jsonObject(...) as?
NSDictionary`.

**Fix (isolation):** **mirror `SendableErrorDocument`** (bottom of
`Palace/Book/Models/BookRegistrySync.swift`). Introduce a `private struct`
carrier `@unchecked Sendable` holding `let value: NSDictionary?`, build it from
the dict, and capture the carrier in the `TPPAsyncDispatch` closure —
`handler(nil, box.value)`. Invariant comment: the dictionary is built once from
a caught error/response and only ever read thereafter (forwarded to `handler`),
so moving it across the dispatch boundary is race-free. Use ONE carrier type for
both sites. Preserve `handler(nil, …)` argument shape and the surrounding
early-returns exactly. **Behavior risk:** none.

---

## Site 2 — `PDFThumbnailStrip.swift` ~132: capture of `provider`
**Warning:** in `Fetcher.fetch()` (`@MainActor final class Fetcher`),
`DispatchQueue.pdfThumbnailRenderingQueue.async { let rendered =
provider.thumbnail(for: page) … }` captures the non-Sendable
`PDFKitThumbnailProvider` into the `@Sendable` dispatch closure.

**Fix (isolation):** **mirror `ImageCompletionBox`** — wrap the provider in a
`private final class` box `@unchecked Sendable` (or a small carrier) captured by
the background-queue closure, invariant: `PDFKitThumbnailProvider.thumbnail(for:)`
is invoked only on `pdfThumbnailRenderingQueue`, and the result is published back
via `DispatchQueue.main.async { self?.image = rendered }` unchanged. Preserve the
`guard image == nil` short-circuit, the `guard let rendered else { return }`, and
the `[weak self]` main hop exactly.
- If `PDFKitThumbnailProvider` (`Palace/PDF/Model/PDFKitThumbnailProvider.swift`)
  is trivially value-immutable / internally-synchronized and you can make it
  honestly `Sendable` WITHOUT touching its behavior, that is also acceptable and
  cleaner — but do NOT restructure its internals. The carrier box is the safe
  default. **Behavior risk:** none.

---

## Site 3 — `CatalogViewModel.swift` ~229: `CatalogRepositoryProtocol` can't exit main actor
**Warning:** `CatalogViewModel` is `@MainActor final class`;
`private let repository: CatalogRepositoryProtocol` is main-actor-isolated. Inside
the `Task.detached(priority: .utility)` entry-point preload, the nested
`group.addTask { … try await self.repository.loadTopLevelCatalog(at: epURL) }`
reads `self.repository` off the main actor → the diagnostic.

**Fix (isolation) — TWO parts:**
1. **Protocol Sendable (bonus cascade decision):** add `: Sendable` to
   `CatalogRepositoryProtocol` in
   `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift:8`.
   The sole conformer `public final class CatalogRepository` is **already
   `@unchecked Sendable`** (`:22`), and the protocol is a stateless 3-async-method
   service, so this is honest and ripples nothing onto closures.
   ```swift
   public protocol CatalogRepositoryProtocol: Sendable {
   ```
2. **Hoist the read out of the detached closure** in `CatalogViewModel`: bind
   `let repository = self.repository` on the main actor BEFORE
   `Task.detached(...)`, and reference the local `repository` (now a Sendable
   value) inside `group.addTask` instead of `self.repository`. This keeps the
   preload off-main at `.utility` priority exactly as before — no isolation or
   priority change to the fetch. **Behavior risk:** none.

Do NOT make `CatalogViewModel` non-`@MainActor` and do NOT move the fetch onto
the main actor (that would change execution context).

---

## Deliverable (paste in your report — NO mutation/xcresult)
For each site: (a) file:symbol + warning, (b) applied fix + mirror pattern,
(c) behavior risk (expected: none). Call out the cross-boundary package edit
(`CatalogRepositoryProtocol: Sendable`) explicitly. Confirm you touched ONLY the
4 files above.
