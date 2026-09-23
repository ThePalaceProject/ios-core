---
name: palacecatalog-swift6-modernization
created: 2026-06-30
author: claude
---

# palacecatalog-swift6-modernization

The tent-pole of the Swift 6 modernization fan-out (playbook proven by #1129
PalaceLogging; modules 2–5 = Keychain/ReadingPosition/TriageBot/Network landed).
PalaceCatalog is the "center of mass" (#1129 sizing: ~56 warnings) and gates
PalaceAuth. Design-first; commit on `feat/swift6-palacecatalog`; PR + SoD (it's a
critical-path-adjacent module — catalog parsing + repository networking).

## Measured scope (2026-06-30, `swift build -Xswiftc -strict-concurrency=complete`)

**66 distinct concurrency-warning locations** (raw 428 incl. duplication +
~130 non-concurrency style warnings — redundant `public` modifiers, "cast always
succeeds" — which are OUT of scope, pre-existing, not Swift-6 work). Concentrated
in 4 hot files:

- `CatalogRepository.swift` — repository + in-memory caches (the heaviest;
  `#MutableGlobalVariable` static caches/formatters + `#SendableClosureCaptures`
  in async load paths).
- `CatalogAPI.swift` — networking layer (closure captures, sending risks).
- `TPPOPDSAcquisition.swift` — OPDS model (Sendable conformances on
  structs/enums; non-Sendable associated values).
- `TPPOpenSearchDescription.swift` — OPDS model (~10).
- `OPDSParser.swift`, `TPPAsync.swift`, `OPDS2Feed.swift` — a few each.

Dominant categories (raw counts): Sendable conformance (~80), SendableClosure-
Captures (~78), MutableGlobalVariable (~66), @Sendable-closure data-race (~26),
SendingRisksDataRace (~12).

## Claims

- **Manifest prep (DONE in this branch):**
  - Drop phantom `.testTarget(name: "PalaceCatalogTests")` — no `Tests/` dir;
    tests live in the app's `PalaceTests` target. Broke standalone `swift build`
    ("overlapping sources"). Same fix as PalaceNetwork #1133.
  - Bump PalaceCatalog macOS host floor 11 → 13 (PalaceLogging dep needs
    OSAllocatedUnfairLock; iOS stays 16; host-build only).
  - Bump **PalaceNetwork** macOS floor 11 → 13 too (latent gap left by #1133 —
    it depends on PalaceLogging/macOS-13 but declared macOS 11; only bites
    standalone builds). One-line cross-package fix, required for resolution.
- **Concurrency (TODO):** fix the 66 by ISOLATION not suppression, per the
  playbook: `#MutableGlobalVariable` → `OSAllocatedUnfairLock<T>` / `let` /
  localize; OPDS model types → `Sendable` (most are value types / Codable —
  largely additive); `#SendableClosureCaptures` → lock or restructure. NEVER
  `nonisolated(unsafe)`.
- **Language mode (TODO, last):** bump `swift-tools-version` 5.9 → 6.0 (source
  target → v6) once warnings are 0 at `complete`.

## Anti-claims

- does NOT use `nonisolated(unsafe)` anywhere (playbook rule).
- does NOT fix the ~130 pre-existing NON-concurrency style warnings (redundant
  `public`, always-true casts) — out of scope; separate cleanup if desired.
- Sendable ripple into consumers (the app target + PalaceAuth) is EXPECTED and
  tracked — PalaceAuth merges AFTER this (it consumes Catalog types).

## Files in scope

- Palace/Packages/PalaceCatalog/Package.swift (manifest: drop testTarget, floor, later v6)
- Palace/Packages/PalaceNetwork/Package.swift (macOS floor 13 — resolution fix)
- Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift
- Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogAPI.swift
- Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisition.swift
- Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOpenSearchDescription.swift
- Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/{OPDSParser,TPPAsync,OPDS2Feed}.swift
- (+ Sendable conformances rippling to other OPDS model files as surfaced)

## Verification (TODO on implementation)

`swift build -Xswiftc -strict-concurrency=complete` → 0 concurrency warnings;
then flip to tools 6.0 and `swift build` (v6 mode) 0/0; full-app iOS CI
build-and-test green (the cross-module Sendable ripple gate); architect + qa SoD.
