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
    // 1) If a download is actively in progress (or registry says `.downloading`), show `.downloadInProgress`.
    if registryState == .downloading || isProcessingDownload {
      return .downloadInProgress
    }

    // 2) If registry says “download failed,” show `.downloadFailed`.
    if registryState == .downloadFailed {
      return .downloadFailed
    }

    // 3) If registry says “downloadSuccessful,” show `.downloadSuccessful`.
    if registryState == .downloadSuccessful {
      return .downloadSuccessful
    }

    // 4) If registry says “downloadNeeded,” show `.downloadNeeded` (i.e. canBorrow).
    if registryState == .downloadNeeded {
      return .downloadNeeded
    }

    // 5) If registry says “used,” show `.used` (e.g. read again).
    if registryState == .used {
      return .used
    }

    // 6) If registry says “holding” (i.e. user is on hold but not ready), show `.holdingFrontOfQueue`.
    if registryState == .holding {
      return .holdingFrontOfQueue
    }

    // 7) If registry says “returnPending,” show `.returning`.
    if registryState == .returning {
      return .returning
    }

    // If none of the above registry‐driven cases applied, try OPDS availability:
    if let availState = stateForAvailability(availability) {
      return availState
    }

    // Finally, nothing matched → `.unsupported`
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
