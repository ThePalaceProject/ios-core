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
    /// The mapping is an **exhaustive `switch` with no `default:`** — the
    /// compiler forces every `TPPBookState` case to be handled here. Phase 7
    /// siblings audit (`.forgeos/audits/phase7-synthesis-2026-05-26.md`) flagged
    /// the previous if-cascade fall-through as the same trap that produced
    /// F-011 (silent `.downloadNeeded` swallow → first-open audiobook hang):
    /// any new `TPPBookState` case would inherit `.unsupported` silently. The
    /// switch makes adding a case a compile error until the mapping is decided.
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
            // “unavailable” means no copies right now, but user can place a hold
            state = .canHold
        }, limited: { limited in
            if limited.copiesAvailable == TPPOPDSAcquisitionAvailabilityCopiesUnknown || limited.copiesAvailable > 0 {
                state = .canBorrow
            } else {
                state = .canHold
            }
        }, unlimited: { _ in
            // “unlimited” means infinite/always‐available → canBorrow
            state = .canBorrow
        }, reserved: { _ in
            // “reserved” means user is on hold but not yet ready → front of queue
            state = .holdingFrontOfQueue
        }, ready: { _ in
            // “ready” means the hold is ready to check out → canBorrow
            state = .canBorrow
        })

        return state
    }
}
