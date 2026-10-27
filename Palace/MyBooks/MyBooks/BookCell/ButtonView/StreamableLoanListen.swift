//
//  StreamableLoanListen.swift
//  Palace
//
//  PP-5402: a loan whose license has not been fetched yet offers Listen when
//  its audiobook can stream. The tap runs the same fulfilment as Download (with
//  streaming on that fetches only the license and starts the background `.lcpa`
//  fetch, PP-5135), then opens the player once the book is playable.
//

import Foundation
import PalaceBookModel

enum StreamableLoanListen {

    /// Whether a `.downloadNeeded` loan can offer Listen instead of Download.
    static func offersListen(book: TPPBook, streamingEnabled: Bool) -> Bool {
        guard streamingEnabled else { return false }
        #if LCP
        return LCPAudiobooks.canOpenBook(book)
        #else
        return false
        #endif
    }

    /// How far a Listen tap's fulfilment has got.
    enum Phase: Equatable {
        /// Fulfilment was asked for and the registry has not moved yet.
        case requested
        /// The registry has shown the fulfilment running.
        case inFlight
    }

    enum Step: Equatable {
        case open
        case wait(Phase)
        case abandon
    }

    /// What a pending Listen does when the registry reports `state`.
    ///
    /// `.downloadNeeded` is the starting state, so it only counts as a fall-back
    /// once the fulfilment has been seen running.
    static func step(_ phase: Phase, on state: TPPBookState) -> Step {
        switch state {
        case .downloadSuccessful, .used:
            return .open
        case .downloading, .SAMLStarted:
            return .wait(.inFlight)
        case .downloadNeeded:
            return phase == .requested ? .wait(.requested) : .abandon
        case .downloadFailed, .unregistered, .returning, .holding, .unsupported:
            return .abandon
        }
    }
}
