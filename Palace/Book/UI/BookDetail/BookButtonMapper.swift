//
//  BookButtonMapper.swift
//  Palace
//
//  Combines TPPBookState (registry state) with OPDS availability
//  into a single BookButtonState. See “stateForAvailability(...)” below.
//  Always call this one function to decide which button(s) to show.
//

import Foundation
import PalaceCatalog
import PalaceBookModel

struct BookButtonMapper {

    /// First look at registryState. If that alone dictates a clear UI state,
    /// return it. Otherwise fall back to OPDS availability via `stateForAvailability(_)`.
    ///
    /// The mapping is an exhaustive `switch` with no `default:`, so adding a
    /// `TPPBookState` case is a compile error until its button state is decided
    /// rather than falling through to `.unsupported` (an unmapped
    /// `.downloadNeeded` once caused a first-open audiobook hang).
    static func map(
        registryState: TPPBookState,
        availability: TPPOPDSAcquisitionAvailability?,
        isProcessingDownload: Bool
    ) -> BookButtonState {
        // Precondition: an active in-flight download short-circuits the
        // registry-state decision tree. Keeps the SAML/borrow handoff window
        // visually consistent even while the registry hasn't flipped yet.
        if isProcessingDownload {
            return .downloadInProgress
        }

        switch registryState {
        case .downloading:
            return .downloadInProgress
        case .SAMLStarted:
            // SAML authentication is part of the download flow — auth completes,
            // then download begins. UI should render "in progress" so the cell
            // doesn't oscillate between Get/Requesting/Downloading. Matches the
            // parallel mapping in `BookButtonState.init?(_:bookRegistry:)`.
            return .downloadInProgress
        case .downloadFailed:
            return .downloadFailed
        case .downloadSuccessful:
            return .downloadSuccessful
        case .downloadNeeded:
            return .downloadNeeded
        case .used:
            return .used
        case .holding:
            if availability is TPPOPDSAcquisitionAvailabilityReady {
                return .canBorrow
            }
            return .holding
        case .returning:
            return .returning
        case .unregistered:
            // No registry signal — derive from OPDS availability. nil
            // availability with no registry state means we genuinely don't know
            // how to render the cell, so .unsupported is the honest answer.
            return stateForAvailability(availability) ?? .unsupported
        case .unsupported:
            return .unsupported
        }
    }

    /// Map OPDS availability (unavailable/limited/unlimited/reserved/ready)
    /// → a BookButtonState, _but only if_ the registry didn’t already claim a higher‐priority state.
    static func stateForAvailability(_ availability: TPPOPDSAcquisitionAvailability?) -> BookButtonState? {
        guard let availability else {
            return nil
        }

        var state: BookButtonState = .unsupported
        availability.match(unavailable: { _ in
            state = .canHold
        }, limited: { limited in
            if limited.copiesAvailable == TPPOPDSAcquisitionAvailabilityCopiesUnknown || limited.copiesAvailable > 0 {
                state = .canBorrow
            } else {
                state = .canHold
            }
        }, unlimited: { _ in
            state = .canBorrow
        }, reserved: { _ in
            state = .holdingFrontOfQueue
        }, ready: { _ in
            state = .canBorrow
        })

        return state
    }
}
