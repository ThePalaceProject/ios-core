//
//  BookButtonMapper.swift
//  Palace
//
//  Combines TPPBookState (registry state) with OPDS availability
//  into a single BookButtonState. See “stateForAvailability(...)” below.
//  Always call this one function to decide which button(s) to show.
//

import Foundation

struct BookButtonMapper {

  /// First look at registryState. If that alone dictates a clear UI state,
  /// return it. Otherwise fall back to OPDS availability via `stateForAvailability(_)`.
  static func map(
    registryState: TPPBookState,
    availability: TPPOPDSAcquisitionAvailability?,
    isProcessingDownload: Bool
  ) -> BookButtonState {
    if registryState == .downloading || isProcessingDownload {
      return .downloadInProgress
    }

    if registryState == .downloadFailed {
      return .downloadFailed
    }

    if registryState == .downloadSuccessful {
      return .downloadSuccessful
    }

    if registryState == .downloadNeeded {
      return .downloadNeeded
    }

    if registryState == .used {
      return .used
    }

    if registryState == .holding {
      return .holding
    }

    if registryState == .returning {
      return .returning
    }

    if let availState = stateForAvailability(availability) {
      return availState
    }

    return .unsupported
  }

  /// Map OPDS availability (unavailable/limited/unlimited/reserved/ready)
  /// → a BookButtonState, _but only if_ the registry didn’t already claim a higher‐priority state.
  static func stateForAvailability(_ availability: TPPOPDSAcquisitionAvailability?) -> BookButtonState? {
    guard let availability else {
      return nil
    }

    var state: BookButtonState = .unsupported
    availability.matchUnavailable { _ in
      // “unavailable” means no copies right now, but user can place a hold
      state = .canHold
    } limited: { _ in
      // “limited” means some copies exist (OR zero), so we treat it as “canBorrow”
      state = .canBorrow
    } unlimited: { _ in
      // “unlimited” means infinite/always‐available → canBorrow
      state = .canBorrow
    } reserved: { _ in
      // “reserved” means user is on hold but not yet ready → front of queue
      state = .holdingFrontOfQueue
    } ready: { _ in
      // “ready” means the hold is ready to check out → canBorrow
      state = .canBorrow
    }

    return state
  }
}
