//
//  ResourcePropertiesLengthTests.swift
//  PalaceTests
//
//  Pins the Readium 3.9.0 JSONValue bridge in the `ResourceProperties.length`
//  extension (AdobeDRMContentProtection.swift). 3.9.0 made the
//  `ResourceProperties` subscript require `JSONValueEncodable & JSONValueDecodable`;
//  `UInt64` is encode-only, so length is persisted as `Int` and bridged back to
//  `UInt64` at this accessor. A regression — storing the wrong type, dropping
//  the bridge, or truncating to 32 bits — breaks one of these round-trips.
//
//  The `length` extension is `public` and compiled into the (DRM) Palace
//  module, so it is reachable here via `@testable import Palace` without a
//  `FEATURE_DRM_CONNECTOR` guard — which the PalaceTests target does not define.
//

import XCTest
import ReadiumShared
@testable import Palace

@MainActor
final class ResourcePropertiesLengthTests: XCTestCase {

    func testLength_roundTripsLargeValueWithoutTruncation() {
        var props = ResourceProperties()
        // > UInt32.max so a 32-bit truncation regression is caught.
        let value: UInt64 = 4_294_967_296
        props.length = value
        XCTAssertEqual(props.length, value,
                       "length must round-trip unchanged through the Int-backed JSONValue store")
    }

    func testLength_isNilWhenUnset() {
        let props = ResourceProperties()
        XCTAssertNil(props.length, "length must be nil when nothing was stored")
    }

    func testLength_zeroRoundTrips() {
        var props = ResourceProperties()
        props.length = 0
        XCTAssertEqual(props.length, 0,
                       "a stored zero must read back as zero, not nil")
    }
}
