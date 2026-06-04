---
name: swarm_5c8ddbd5-contract-A-AdapterProtocol
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [network]
description: Module A — AudiobookVendorAdapter protocol
---

# Module A — AudiobookVendorAdapter protocol

## In-scope files (exclusive write)
- NEW `Palace/Audiobooks/Vendors/AudiobookVendorAdapter.swift`
- NEW `PalaceTests/Audiobook/Vendors/AudiobookVendorAdapterTests.swift`

## Out-of-scope (read-only)
- `Palace/Audiobooks/AudiobookLoader.swift`
- `Palace/Audiobooks/LCP/LCPAudiobooks.swift`
- `Palace/Audiobooks/AudioBookVendors+Extensions.swift`
- `Palace/Audiobooks/AudioBookVendorsHelper.swift`
- All files in the swarm-wide don't-touch list (see plan.md)

## Public types exposed

```swift
protocol AudiobookVendorAdapter {
    /// Returns true if this adapter is responsible for loading `book`.
    /// Adapters are consulted in priority order (LCP first, then network
    /// adapters); first match wins. Must be cheap and synchronous.
    func canHandle(_ book: TPPBook) -> Bool

    /// Produce a manifest JSON dict and optional DRM decryptor for `book`.
    /// May perform I/O (disk read, network fetch, license re-download).
    /// Must complete on the main thread. Errors map to existing
    /// AudiobookLoadError cases.
    func resolveManifest(
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    )
}
```

## Types consumed
- `TPPBook` (Palace/Book)
- `DRMDecryptor` (PalaceAudiobookToolkit)
- `AudiobookLoadError` (existing in `Palace/Audiobooks/AudiobookLoader.swift`)

## Tests owned

`PalaceTests/Audiobook/Vendors/AudiobookVendorAdapterTests.swift`
- `testProtocol_canHandleMustBeSync` — compile-time test via a no-op conformance
- `testProtocol_resolveManifestSignature` — compile-time test
- `testFirstMatchPriorityOrder` — if a registry helper type is included

The protocol file itself is <=80 LOC including doc comments. Tests focus on compile-time correctness of the protocol shape, not behavior — behavior is per-adapter in Modules B/C/D.

## Acceptance criteria
- File <=80 LOC, doc-commented per CLAUDE.md style
- Compiles in **both** Palace AND Palace-noDRM targets (no `#if LCP` gate on the protocol itself)
- No imports of `PalaceAudiobookToolkit` beyond `DRMDecryptor`
- Public surface stable — once shipped, Modules B/C/D rely on it

## Implementer prompt

You are Module A implementer for swarm_5c8ddbd5. Read your contract at `.forgeos/swarms/swarm_5c8ddbd5/contracts/A-AdapterProtocol.md`. Write exactly one protocol file and one test file.

The protocol shape is consumed by three downstream modules (B, C, D) — your choice locks them in. Default to the simplest shape that matches the existing `resolveManifestAndDecryptor` surface in `Palace/Audiobooks/AudiobookLoader.swift`. Do **NOT** introduce async/await or `@MainActor` — the loader is callback-based today and Swarm 3 will modernize concurrency. Stay callback-shaped.

Use `scripts/pbxproj_add_swift.rb` to add both files to `Palace.xcodeproj` for both Palace AND Palace-noDRM targets (the protocol must compile in both).

Validate: `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds.

When done, write `.forgeos/swarms/swarm_5c8ddbd5/transcripts/A-AdapterProtocol.md` with: files added (the 2), tests added (the 3 test names), key decisions (any shape choices that depart from naive translation of `resolveManifestAndDecryptor`), and any gaps the integrator must handle.

Do NOT commit. Do NOT push. Stage the changes for the integrator.
