//
//  AppContainerAudiobookFactoryTests.swift
//  PalaceTests
//
//  Created by swarm_03acb10a Module A — audiobook systemic overhaul Phase 3.
//
//  Exercises the two cached factory accessors on AppContainer that replace the
//  `AudiobookSessionManager.shared` / `PlaybackBootstrapper.shared` singletons.
//  These accessors mirror the `_bookCellModelCache` / `_samplePreviewManager`
//  pattern: a single shared instance pinned in a `@MainActor` static cell,
//  lazy-constructed on first read.
//

import XCTest
@testable import Palace

final class AppContainerAudiobookFactoryTests: XCTestCase {

    /// `audiobookSession` must return the same instance on repeated reads —
    /// the cache cell `_audiobookSession` is the single source of truth. A
    /// regression that drops the cache (e.g. constructs a fresh manager per
    /// read) would split the toolkit's CarPlay command target list across
    /// phantom managers and break play/pause from the lock screen.
    @MainActor
    func testAudiobookSession_returnsSameInstanceAcrossReads() {
        let container = AppContainer.production()
        let first = container.audiobookSession
        let second = container.audiobookSession
        XCTAssertTrue(
            (first as AnyObject) === (second as AnyObject),
            "audiobookSession must return the cached instance on repeated reads"
        )
    }

    /// `playbackBootstrapper` must return the same instance on repeated reads.
    /// CarPlay relies on `ensureInitializedForCarPlay()` being idempotent
    /// against a single bootstrapper — a fresh instance per read would
    /// re-register `MPRemoteCommandCenter` targets and duplicate them.
    @MainActor
    func testPlaybackBootstrapper_returnsSameInstanceAcrossReads() {
        let container = AppContainer.production()
        let first = container.playbackBootstrapper
        let second = container.playbackBootstrapper
        XCTAssertTrue(
            first === second,
            "playbackBootstrapper must return the cached instance on repeated reads"
        )
    }

    /// Cross-call coherence: a fresh `AppContainer.production()` read returns
    /// the same backing `_cached` struct, and the audiobook factories must
    /// share the same static cache cell. This is the "no parallel session
    /// per container" invariant. If `_audiobookSession` were demoted to an
    /// instance field (which AppContainer-as-struct cannot store mutably) or
    /// if a regression introduced per-call construction, two `production()`
    /// reads would yield distinct session/bootstrapper identities and
    /// CarPlay→phone command routing would fork. The bootstrapper's session
    /// provider closure is `private` (owned by Module B / PlaybackBootstrapper)
    /// so this test asserts the externally-observable coherence rather than
    /// reflecting on the closure directly.
    @MainActor
    func testAudiobookFactories_areCoherentAcrossProductionReads() {
        let containerA = AppContainer.production()
        let containerB = AppContainer.production()

        let sessionA = containerA.audiobookSession
        let sessionB = containerB.audiobookSession
        XCTAssertTrue(
            (sessionA as AnyObject) === (sessionB as AnyObject),
            "audiobookSession must share a single instance across all AppContainer.production() reads"
        )

        let bootstrapperA = containerA.playbackBootstrapper
        let bootstrapperB = containerB.playbackBootstrapper
        XCTAssertTrue(
            bootstrapperA === bootstrapperB,
            "playbackBootstrapper must share a single instance across all AppContainer.production() reads"
        )
    }
}
