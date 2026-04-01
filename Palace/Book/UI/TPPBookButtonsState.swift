import Foundation

@objc enum TPPBookButtonsState: Int {
  case canBorrow
  case canHold
  case holding
  case holdingFOQ // Front Of Queue: a book that was Reserved and now it's Ready for borrow
  case downloadNeeded
  case downloadSuccessful
  case used
  case downloadInProgress
  case downloadFailed
  case unsupported
}

/// Returns a Borrow, Keep, Hold, Holding, or HoldingFOQ state.
func TPPBookButtonsViewStateWithAvailability(_ availability: TPPOPDSAcquisitionAvailability?) -> TPPBookButtonsState {
  guard let availability = availability else {
    TPPErrorLogger.logError(
      withCode: .noURL,
      summary: "Unable to determine BookButtonsViewState because no Availability was provided",
      metadata: nil
    )
    return .unsupported
  }

  var state: TPPBookButtonsState = .unsupported

  availability.match(
    unavailable: { _ in state = .canHold },
    limited: { _ in state = .canBorrow },
    unlimited: { _ in state = .canBorrow },
    reserved: { _ in state = .holding },
    ready: { _ in state = .holdingFOQ }
  )

  return state
}
