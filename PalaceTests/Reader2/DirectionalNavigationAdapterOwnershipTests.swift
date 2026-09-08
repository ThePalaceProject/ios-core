//
//  DirectionalNavigationAdapterOwnershipTests.swift
//  PalaceTests
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import UIKit
@testable import Palace
import ReadiumNavigator
import ReadiumShared

/// Pins the Readium ownership contract that EPUB edge-tap paging depends on.
///
/// Edge taps in the EPUB reader are served by `DirectionalNavigationAdapter`.
/// `bind(to:)` registers closures that capture the adapter **weakly**, so the
/// navigator's observer list does not keep it alive — whoever creates the
/// adapter must own it. `TPPEPUBViewController` does, via its
/// `directionalNavigationAdapter` property.
///
/// This is not defensive theory. Readium 3.7 captured `[self, ...]` strongly, so
/// binding an unowned temporary worked by accident. 3.9 changed the capture to
/// `[weak self, ...]`; the temporary began deallocating as soon as `init`
/// returned, every edge tap hit `guard let self` and returned `false`, and the
/// event fell through to the toolbar-toggle observer. Tapping the page edge
/// showed the chrome instead of turning the page, in every release from Palace
/// 3.2.0 onward. Nothing on our side changed and nothing failed to compile.
///
/// If a future Readium bump restores strong capture, `testBindingAloneDoesNotRetain`
/// fails — which is the signal that the ownership property is no longer load-bearing,
/// not a reason to delete the test.
///
/// SEAM: the natural test here would deliver a real edge tap and assert the page
/// turned. It cannot be written from this module: `PointerEvent` has no public
/// initializer (its memberwise init is internal to ReadiumNavigator), so a test
/// outside that module cannot synthesize the event a tap produces. Ownership is
/// therefore asserted directly, which is the property the defect actually turned on.
@MainActor
final class DirectionalNavigationAdapterOwnershipTests: XCTestCase {

    private func makeAdapter() -> DirectionalNavigationAdapter {
        DirectionalNavigationAdapter(
            pointerPolicy: DirectionalNavigationAdapter.PointerPolicy(
                types: [.touch],
                edges: .horizontal,
                ignoreWhileScrolling: true,
                horizontalEdgeThresholdPercent: 0.2
            ),
            animatedTransition: true
        )
    }

    /// Binding does not confer ownership — the defect's precondition.
    func testBindingAloneDoesNotRetainAdapter() {
        let navigator = MockVisualNavigator()
        weak var weakAdapter: DirectionalNavigationAdapter?

        do {
            let adapter = makeAdapter()
            weakAdapter = adapter
            adapter.bind(to: navigator)
            XCTAssertNotNil(weakAdapter, "Adapter must be alive while a strong reference is held")
        }

        XCTAssertNil(
            weakAdapter,
            """
            Binding retained the adapter. Readium's `bind(to:)` captures the adapter \
            weakly, so an unowned temporary must deallocate. If this now survives, the \
            capture semantics changed upstream and TPPEPUBViewController's ownership \
            property is no longer what keeps edge taps working — re-check that file.
            """
        )
    }

    /// A held reference survives binding — the shape `TPPEPUBViewController` uses.
    func testAdapterHeldByOwnerSurvivesBinding() {
        let navigator = MockVisualNavigator()
        weak var weakAdapter: DirectionalNavigationAdapter?
        var owner: DirectionalNavigationAdapter?

        do {
            let adapter = makeAdapter()
            weakAdapter = adapter
            adapter.bind(to: navigator)
            owner = adapter
        }

        XCTAssertNotNil(
            weakAdapter,
            "An adapter stored by its owner must outlive the scope that created it — this is the fix for EPUB edge-tap paging"
        )

        owner = nil
        XCTAssertNil(weakAdapter, "Releasing the owner must release the adapter — no retain cycle through the navigator")
    }
}
