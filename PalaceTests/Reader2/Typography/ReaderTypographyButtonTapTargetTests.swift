//
//  ReaderTypographyButtonTapTargetTests.swift
//  PalaceTests
//
//  The typography button ships as a UIBarButtonItem custom view, where the
//  view's frame is the whole tap area. These tests pin the 44pt HIG minimum
//  and the touch region it produces.
//

import XCTest
@testable import Palace

@MainActor
final class ReaderTypographyButtonTapTargetTests: XCTestCase {

    /// A bar button item's custom view supplies its own tap area, so the
    /// default-initialised button must already meet the 44pt minimum — the
    /// reader toolbar constructs it with no frame.
    func testDefaultInit_tapTargetMeetsHIGMinimum() {
        let button = ReaderTypographyButtonUIKit()

        XCTAssertGreaterThanOrEqual(button.bounds.width, 44,
                                    "Custom-view width is the tap area; 44pt is the HIG minimum")
        XCTAssertGreaterThanOrEqual(button.bounds.height, 44,
                                    "Custom-view height is the tap area; 44pt is the HIG minimum")
    }

    /// The frame, not the artwork, supplies the target: a 17pt symbol is about
    /// half the minimum, so a button sized to its image would be under it.
    func testDefaultInit_artworkIsSmallerThanTheTapTarget() throws {
        let button = ReaderTypographyButtonUIKit()

        let artworkSize = try XCTUnwrap(button.image(for: .normal)?.size)

        XCTAssertLessThan(artworkSize.width, button.bounds.width,
                          "Artwork stays at its natural size inside the larger tap target")
        XCTAssertLessThan(artworkSize.height, button.bounds.height,
                          "Artwork stays at its natural size inside the larger tap target")
    }

    /// What a thumb actually meets: every point across the minimum square has
    /// to land on the button. With no frame the hit region is empty and
    /// `hitTest` returns nil at all of them.
    func testDefaultInit_acceptsTouchesAcrossTheWholeMinimumTarget() {
        let button = ReaderTypographyButtonUIKit()

        let probes = [
            CGPoint(x: 1, y: 1),
            CGPoint(x: 22, y: 22),
            CGPoint(x: 43, y: 1),
            CGPoint(x: 1, y: 43),
            CGPoint(x: 43, y: 43)
        ]

        for point in probes {
            XCTAssertTrue(button.hitTest(point, with: nil) === button,
                          "Point \(point) is inside the 44pt minimum target and must hit the button")
        }
    }

    /// A point outside the minimum square is not a hit — proves the assertions
    /// above measure a bounded region rather than a view that swallows
    /// everything.
    func testDefaultInit_rejectsTouchesOutsideItsBounds() {
        let button = ReaderTypographyButtonUIKit()

        XCTAssertNil(button.hitTest(CGPoint(x: 80, y: 80), with: nil))
    }

    /// A caller that asks for a larger frame keeps it; the minimum only grows a
    /// frame that is below it.
    func testExplicitLargerFrame_isPreserved() {
        let button = ReaderTypographyButtonUIKit(frame: CGRect(x: 0, y: 0, width: 60, height: 60))

        XCTAssertEqual(button.bounds.width, 60)
        XCTAssertEqual(button.bounds.height, 60)
    }

    /// A frame below the minimum is grown to it in each dimension.
    func testExplicitUndersizedFrame_isGrownToTheMinimum() {
        let button = ReaderTypographyButtonUIKit(frame: CGRect(x: 7, y: 9, width: 22, height: 22))

        XCTAssertEqual(button.bounds.width, 44)
        XCTAssertEqual(button.bounds.height, 44)
        XCTAssertEqual(button.frame.origin, CGPoint(x: 7, y: 9),
                       "Growing the tap target must not move the button in the toolbar")
    }

    /// The enlarged frame must still deliver the tap: a target that grew but
    /// lost its action would read as a button that does nothing.
    func testTouchUpInside_invokesOnTap() {
        let button = ReaderTypographyButtonUIKit()
        var tapCount = 0
        button.onTap = { tapCount += 1 }

        button.sendActions(for: .touchUpInside)

        XCTAssertEqual(tapCount, 1)
    }
}
