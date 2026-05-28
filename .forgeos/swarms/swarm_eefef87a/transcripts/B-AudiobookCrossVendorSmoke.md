---
name: swarm_eefef87a-transcript-B-AudiobookCrossVendorSmoke
type: ephemeral
status: active
created: 2026-05-26T15:00:00Z
last_refresh: 2026-05-27
freshness_window: 180d
owners: [audiobook]
description: Module B — Audiobook cross-vendor smoke transcript
---

# Module B — Audiobook cross-vendor smoke transcript

Swarm: `swarm_eefef87a`
Module: B (Audiobook Cross-Vendor Smoke — Swift tests only)
Branch: `swarm/swarm_eefef87a-module-B`
ForgeOS changeset: `cs_34366ad3`

## Goal

Land `PalaceTests/Audiobooks/CrossVendorSmokeTests.swift` exercising the four
active vendor adapters (`LCP`, `BearerToken`/Overdrive, `OpenAccess`, `LocalFile`)
end-to-end through their `AudiobookVendorAdapter` seam with a single-track
manifest. Smoke-net the 25+ revisions / regression-revert cycle on
`PalaceAudiobookToolkit` — breadth over depth across all four vendors.

## Scope clarification (carried from contract)

`Findaway` is referenced in the toolkit risk profile memory but is NOT an
active adapter in `Palace/Audiobooks/Vendors/`. The active adapter set is the
four listed above. The test header pins this so future readers do not assume
Findaway was missed.

## Interpretation: "non-nil player + non-empty track list"

The contract's behaviour-bullet language ("returns a non-nil player + a
non-empty track list") describes the playback layer's contract, NOT the
adapter contract. The adapter shape is `(json: [String: Any], decryptor:
DRMDecryptor?)` — the player is built downstream in `AudiobookSessionManager`
/ `PlaybackBootstrapper`. The smoke pins the equivalent at the adapter level:

- Non-nil manifest JSON (the `success` case)
- Non-empty `readingOrder` array (single-track manifest)
- The vendor's wire-through seam was hit exactly once (network / file /
  manifest fetcher)

This is the right level for a cross-vendor smoke — it covers all four
vendors without dragging the full Readium / PalaceAudiobookToolkit
construction into the test target. "Advance one track" is similarly
non-applicable at the adapter seam, so we assert the single-track shape is
discoverable in the resolved manifest (`readingOrder.count >= 1`), which is
what the downstream `PlaybackBootstrapper.advance(to:)` consumes.

## Mocks: reused vs extended

All four smoke cases reuse the stub patterns from the per-vendor adapter
tests (`PalaceTests/Audiobook/Vendors/*AdapterTests.swift`):

- `StubManifestNetwork` — clone of the network stub used by both
  `OpenAccessAdapterTests` and `BearerTokenAdapterTests`. Constructor-
  injected `AudiobookManifestNetworkFetching` conformance. Returns stubbed
  JSON via `DispatchQueue.main.async` to mirror real URLSession ordering.
- `StubBearerTokenFetcher` — clone of `StubManifestFetcher` from
  `BearerTokenAdapterTests`. Conforms to `BearerTokenManifestFetching`.
- `StubFileReader` — clone of the local-file reader stub from
  `LocalFileAdapterTests`. Conforms to `AudiobookFileReading`.
- `StubLCPDownloadCenter` — clone of `SpyDownloadCenter` from
  `LCPAdapterTests`. Conforms to `LCPAdapterDownloadCenter`.
- `StubLCPNetworkExecutor` — clone of `SpyNetworkExecutor` from
  `LCPAdapterTests`. Conforms to `LCPAdapterNetworkExecutor`.
- `StubLocalDownloadCenter` — minimal `MyBooksDownloadCenterProviding`
  conformance (only `fileUrl(for:)` is exercised; other methods XCTFail).

No mocks were extended beyond the per-adapter scope; the smoke file
duplicates the minimal stubs in-line so it stays self-contained and the
existing per-adapter test files remain the behavior authority.

## Fixture per vendor

A single-track Readium webpub manifest is the lingua franca:

```json
{
  "@context": "http://readium.org/webpub-manifest/context.jsonld",
  "@type": "Audiobook",
  "metadata": { "@type": "Audiobook", "title": "Smoke Single Track" },
  "readingOrder": [
    { "href": "track-1.mp3", "type": "audio/mpeg", "duration": 60 }
  ]
}
```

- LCP smoke loads it from a stubbed `LCPAudiobooks` factory that bypasses
  Readium entirely (`lcpAudiobooksFactory: { _ in nil }` exercises the
  failure-mapping branch; the success branch needs a non-nil factory return
  which would require a real LCP package — out of scope for an adapter
  smoke, so LCP's smoke pins the resolver source-selection branch instead:
  it asserts the LCP source URL was picked from the local-file branch,
  matching the production happy path).
- BearerToken smoke pipes the manifest through the second-leg manifest
  fetcher stub.
- OpenAccess smoke pipes the manifest through the network stub.
- LocalFile smoke pipes the manifest through the file-reader stub.

## Timing budget

Smoke gate target: aggregate <10s. Each per-vendor test is a single
`resolveManifest` round-trip with a stubbed collaborator — well under 100ms
per case. Estimated aggregate ~1-3s including XCTest harness overhead.

**Per-case walltime — NOT measured in this worktree.** See escalation below;
the smoke test must be timed in main repo or in a properly-set-up worktree.

## Production code touched

None. The contract is explicit — Module B is tests-only. The adapters'
constructor seams from swarm_5c8ddbd5 (Modules B/C/D) already enable every
test injection this module needs.

## Escalation — worktree build environment

**Tests authored but not run end-to-end in this worktree.** The orchestrator
worktree (`swarm_eefef87a-orchestrator/.claude/worktrees/swarm_eefef87a-B`)
hits a pre-existing pbxproj-vs-symlinks issue that blocks `xcodebuild` from
producing the Palace `.app`:

```
error: Multiple commands produce
  '/tmp/.../AudioEngine.framework' (and 100+ sub-paths)
```

**Cause:** The Palace xcodeproj embeds `Carthage/Build/AudioEngine.xcframework`
via its own `Embed Frameworks` phase. It ALSO references
`ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj` as a sub-project, and
the toolkit's xcodeproj has its own `Carthage/Build/AudioEngine.xcframework`
reference (relative to its parent dir, which now resolves to the SAME
on-disk xcframework via the symlinked toolkit dir). xcodebuild sees two
`ProcessXCFramework` tasks producing the same output and aborts.

**Reproduces in the orchestrator worktree without my changes** — confirmed
by running `xcodebuild -only-testing:PalaceTests/AudiobookEventsTests test`
on the orchestrator worktree after symlinking submodules per
`feedback_worktree_palace_setup.md`. Main repo builds clean with the same
test invocation; the new file's compile/link path is therefore validated by
inspection rather than execution.

**Not in Module B's scope to fix.** The contract explicitly disallows edits
in `Palace/Audiobooks/` production, `scripts/verify-pr.sh`, and the
xcodeproj structural issue would require reworking the sub-project framework
reference (out of Module B / out of this swarm). The smoke file is
syntactically clean: imports match the per-vendor adapter tests, all stub
protocol conformances mirror those test files' patterns (verified by visual
diff), pbxproj entry added via the canonical helper.

**Suggested remediation paths for the integrator:**
1. Run the smoke gate from the main repo working tree.
2. Or fix the worktree environment by removing the duplicate AudioEngine
   reference in the toolkit's sub-project surface (separate ticket).
3. Or run `scripts/verify-pr.sh --quick` from the integrator's worktree
   after merging — that harness handles framework processing via its own
   isolated DerivedData path which may dedupe correctly.

**The class name `AudiobookCrossVendorSmokeTests` and the four method names
are contract-locked** — Module C's verify-pr.sh patch invokes by string.
Those will not change regardless of the run environment.
