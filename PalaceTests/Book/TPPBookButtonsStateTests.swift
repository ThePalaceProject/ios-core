import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class TPPBookButtonsStateTests: XCTestCase {

  func testStateForNilAvailability_returnsUnsupported() {
    let state = TPPBookButtonsViewStateWithAvailability(nil)
    XCTAssertEqual(state, .unsupported,
      "A nil availability must map to .unsupported. The function logs an error in this branch — flipping the return to any other state masks the missing-availability condition.")
  }

  func testStateForUnavailable_returnsCanHold() {
    let unavailable = TPPOPDSAcquisitionAvailabilityUnavailable(
      copiesHeld: 3,
      copiesTotal: 5
    )
    let state = TPPBookButtonsViewStateWithAvailability(unavailable)
    XCTAssertEqual(state, .canHold,
      "Unavailable (0 copies available) must map to .canHold so the UI offers a Place Hold action. Mapping to .canBorrow here would allow users to borrow books with 0 available copies — a server-double-issuance race.")
  }

  func testStateForLimited_returnsCanBorrow() {
    let limited = TPPOPDSAcquisitionAvailabilityLimited(
      copiesAvailable: 2,
      copiesTotal: 5,
      since: Date(),
      until: Date().addingTimeInterval(86_400)
    )
    let state = TPPBookButtonsViewStateWithAvailability(limited)
    XCTAssertEqual(state, .canBorrow,
      "Limited availability with copies > 0 must map to .canBorrow. Mapping to .canHold would push every user into the holds queue even when copies are available — wrong UX for the most common path.")
  }

  func testStateForUnlimited_returnsCanBorrow() {
    let unlimited = TPPOPDSAcquisitionAvailabilityUnlimited()
    let state = TPPBookButtonsViewStateWithAvailability(unlimited)
    XCTAssertEqual(state, .canBorrow,
      "Unlimited availability (open-access / DRM-free) must map to .canBorrow. A mutant flipping this to .canHold would block ALL anonymous/open-access borrowing.")
  }

  func testStateForReserved_returnsHolding() {
    let reserved = TPPOPDSAcquisitionAvailabilityReserved(
      holdPosition: 7,
      copiesTotal: 5,
      since: Date(),
      until: nil
    )
    let state = TPPBookButtonsViewStateWithAvailability(reserved)
    XCTAssertEqual(state, .holding,
      "Reserved (user is in the holds queue but not at front) must map to .holding. Confusing this with .holdingFOQ (Ready) would falsely tell the user their hold is ready to borrow.")
  }

  func testStateForReady_returnsHoldingFOQ() {
    let ready = TPPOPDSAcquisitionAvailabilityReady(
      since: Date(),
      until: Date().addingTimeInterval(86_400)
    )
    let state = TPPBookButtonsViewStateWithAvailability(ready)
    XCTAssertEqual(state, .holdingFOQ,
      "Ready (front of queue) must map to .holdingFOQ so the UI prompts the user to claim their hold. Confusing with .holding would leave the user perpetually waiting on a ready loan.")
  }

  func testAllFiveAvailabilityKindsProduceDistinctStates_exceptLimitedAndUnlimited() {
    // Limited and Unlimited both map to .canBorrow by design (both offer borrow).
    // The other three (Unavailable, Reserved, Ready) must each be distinct.
    let unavailable = TPPBookButtonsViewStateWithAvailability(
      TPPOPDSAcquisitionAvailabilityUnavailable(copiesHeld: 0, copiesTotal: 1)
    )
    let reserved = TPPBookButtonsViewStateWithAvailability(
      TPPOPDSAcquisitionAvailabilityReserved(holdPosition: 1, copiesTotal: 1, since: nil, until: nil)
    )
    let ready = TPPBookButtonsViewStateWithAvailability(
      TPPOPDSAcquisitionAvailabilityReady(since: nil, until: nil)
    )
    XCTAssertNotEqual(unavailable, reserved, "Unavailable and Reserved must produce different states — they trigger different user actions (Place Hold vs. nothing).")
    XCTAssertNotEqual(reserved, ready, "Reserved and Ready must produce different states — Ready means borrow is now possible, Reserved means it isn't yet.")
    XCTAssertNotEqual(unavailable, ready, "Unavailable and Ready must produce different states.")
  }
}
