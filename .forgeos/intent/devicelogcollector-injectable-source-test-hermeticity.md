---
name: devicelogcollector-injectable-source-test-hermeticity
created: 2026-07-21
author: claude-opus-4-8
---

**ADR refs:** none — no prior recorded decisions for the `testing`/`architecture`
areas touching DeviceLogCollector. This extends the PP-3651 precedent
(ErrorLogExporterTests stopped scanning the live OSLogStore) rather than
contradicting any decision.

## Context

Full-suite CI hangs: `DeviceLogCollectorTests.testCollectLogs_reportsEntryCount`
timed out at exactly 120.000s (surfaced now that #1305 made CI fail-closed),
taking `ImageLoaderTests` down as worker collateral. Root cause: `collectLogs`
reads `OSLogStore(scope: .currentProcessIdentifier)` and walks every os_log
entry the process emitted — a process-global *monotonic accumulator* whose size
grows with the number of tests that ran before. In isolation it's ~2s; under the
7k-test suite the store is huge, so a live scan (even `lastDays: 1`, since a
minutes-old CI process has all its logs younger than 1 day) blows the per-test
time budget. This is a distinct class from the handoff doc's "corrupted
singleton" polluters — you cannot reset the OS log store, so reset-registration
cannot fix it. The fix is to decouple the tests from the accumulator.

## Claims

- adds struct `DeviceLogEntry` (Sendable value type) to `DeviceLogCollector.swift`
- adds injectable `entrySource` (plus `maxEntries`/`maxOutputBytes`) init
  parameters to `DeviceLogCollector`, defaulting to the live OSLogStore adapter
- adds static `DeviceLogCollector.liveOSLogStoreEntries(days:maxEntries:)` — the
  production default source, the only remaining live-store reader
- migrates `collectLogs` to iterate the injected `entrySource` instead of
  reading `OSLogStore` inline; formatting/counting/truncation logic preserved
- migrates `DeviceLogCollectorTests` to drive an injected fixture source
  (hermetic, load-independent) and assert exact formatting / entry count /
  truncation / error-path behavior
- migrates the two `CoverageGapTests3.DeviceLogCollectorGapTests` cases off
  `DeviceLogCollector.shared` (live scan) onto an injected fixture source

## Anti-claims

- does NOT change the on-wire output format of `collectLogs` (header, per-line
  format, end marker, truncation note all byte-preserved for the production
  Developer-Settings export path)
- does NOT touch `ErrorLogExporter` production behavior or its already-fixed test
- does NOT touch any critical-path file (auth / DRM / borrow / download / sync)
- does NOT alter `DeviceLogCollector.shared` production behavior — the default
  source is the live OSLogStore, identical to today

## Files in scope

- Palace/Logging/DeviceLogCollector.swift
- PalaceTests/Logging/DeviceLogCollectorTests.swift
- PalaceTests/CoverageGapTests3.swift
