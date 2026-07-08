//
//  BookButtonState.swift
//  Palace
//
//  Created by Maurice Carrier on 2/2/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import PalaceCatalog

enum BookButtonState: Equatable {
    case canBorrow
    case canHold
    case holding
    case holdingFrontOfQueue
    case downloadNeeded
    case downloadSuccessful
    case used
    case downloadInProgress
    case returning
    case managingHold
    case downloadFailed
    case unsupported
}

extension BookButtonState {
    func buttonTypes(book: TPPBook, previewEnabled: Bool = true) -> [BookButtonType] {
        var buttons = [BookButtonType]()

        switch self {
        case .canBorrow:
            buttons.append(.get)
            if book.hasSample && previewEnabled {
                buttons.append(book.isAudiobook ? .audiobookSample : .sample)
            }
        case .canHold:
            buttons.append(.reserve)
            if book.hasSample && previewEnabled {
                buttons.append(book.isAudiobook ? .audiobookSample : .sample)
            }
        case .holding, .holdingFrontOfQueue:
            if isHoldReady(book: book) {
                buttons = [.get, .cancelHold]
            } else {
                buttons.append(.manageHold)

                if book.hasSample && previewEnabled {
                    buttons.append(book.isAudiobook ? .audiobookSample : .sample)
                }
            }

        case .managingHold:
            if isHoldReady(book: book) {
                buttons = [.get, .cancelHold]
            } else {
                buttons = [.cancelHold]
            }
        case .downloadNeeded:
            // PP-4161 Option (c): purely presentation-layer mapping. After a
            // streaming-HTML borrow the registry transitions to its NORMAL
            // `.downloadNeeded` state (no state-machine shortcut). Here we map
            // that state directly to `[.readStreaming, .return]` — there is no
            // download phase for streaming-media, so the user goes straight
            // from borrow to read. The BorrowOperation:453 guard prevents the
            // auto-download chain from firing for these books.
            //
            // Exhaustive (no `default:`) — F-011 class-of-bug guard. Compiler
            // flags this if TPPBookContentType gains a case so a future
            // content type can't silently fall through to the legacy
            // `[.download, .return]` mapping.
            switch book.defaultBookContentType {
            case .streamingHTML:
                buttons = [.readStreaming, .return]
            case .epub, .pdf, .audiobook, .unsupported:
                if let authDef = AppContainer.production().accountsManager.currentUserAccount.authDefinition,
                   authDef.needsAuth || book.defaultAcquisitionIfOpenAccess != nil {
                    buttons = [.download, .return]
                } else {
                    buttons = [.download, .remove]
                }
            }
        case .downloadSuccessful, .used:
            switch book.defaultBookContentType {
            case .audiobook:
                buttons.append(.listen)
            case .pdf, .epub:
                buttons.append(.read)
            case .streamingHTML:
                // PP-4161: a streaming-HTML title that's somehow in
                // .downloadSuccessful (e.g. carried over from a prior session
                // where the registry persisted that state) still uses the
                // streaming reader — there's nothing on disk to read.
                buttons.append(.readStreaming)
            case .unsupported:
                break
            }

            if let authDef = AppContainer.production().accountsManager.currentUserAccount.authDefinition,
               authDef.needsAuth ||
                book.defaultAcquisitionIfOpenAccess != nil {
                buttons.append(.return)
            } else {
                buttons.append(.remove)
            }
        case .downloadInProgress:
            buttons = [.cancel]
        case .downloadFailed:
            buttons = [.cancel, .retry]
        case .returning:
            buttons = [.returning]
        case .unsupported:
            return []
        }

        if !book.supportsDeletion(for: self) {
            buttons = buttons.filter {
                $0 != .return || $0 != .remove
            }
        }

        return buttons
    }

    private func isHoldReady(book: TPPBook) -> Bool {
        guard let availability = book.defaultAcquisition?.availability else { return false }

        var isReady = false
        availability.match(unavailable: { _ in
            isReady = false
        }, limited: { _ in
            isReady = false
        }, unlimited: { _ in
            isReady = false
        }, reserved: { _ in
            isReady = false  // Still waiting in queue
        }, ready: { _ in
            isReady = true   // Hold is ready to borrow!
        })

        return isReady
    }
}

extension BookButtonState {
    init?(_ book: TPPBook, bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry) {
        let bookState = bookRegistry.state(for: book.identifier)
        switch bookState {
        case .unregistered, .holding:
            guard let buttonState = Self.stateForAvailability(book.defaultAcquisition?.availability) else {
                TPPErrorLogger.logError(withCode: .noURL, summary: "Unable to determine BookButtonsViewState because no Availability was provided")
                return nil
            }

            self = buttonState
        case .downloadNeeded:
            #if LCP
            if LCPAudiobooks.canOpenBook(book) {
                self = .downloadSuccessful
            } else {
                self = .downloadNeeded
            }
            #else
            self = .downloadNeeded
            #endif
        case .downloadSuccessful:
            self = .downloadSuccessful
        case .SAMLStarted, .downloading:
            // SAML started is part of download process, in this step app does authenticate user but didn't begin file downloading yet
            // The cell should present progress bar and "Requesting" description on its side
            self = .downloadInProgress
        case .downloadFailed:
            self = .downloadFailed
        case .used:
            self = .used
        case .unsupported:
            self = .unsupported
        case .returning:
            self = .returning
        }
    }
}

extension BookButtonState {
    static func stateForAvailability(_ availability: TPPOPDSAcquisitionAvailability?) -> BookButtonState? {
        guard let availability else {
            return nil
        }

        var state: BookButtonState = .unsupported
        availability.match(unavailable: { _ in
            state = .canHold
        }, limited: { limited in
            // Check if copies are actually available to borrow
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
            state = .canBorrow  // Hold is ready, user can borrow
        })

        return state
    }
}

extension TPPBook {
    func supportsDeletion(for state: BookButtonState, bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry) -> Bool {
        var fullfillmentRequired = false
        #if FEATURE_DRM_CONNECTOR
        fullfillmentRequired = state == .holding && self.revokeURL != nil
        #endif

        let hasFullfillmentId = bookRegistry.fulfillmentId(forIdentifier: self.identifier) != nil
        let isFullfiliable = !(hasFullfillmentId && fullfillmentRequired) && self.revokeURL != nil
        let needsAuthentication = self.defaultAcquisitionIfOpenAccess == nil && AppContainer.production().accountsManager.currentUserAccount.authDefinition?.needsAuth ?? false

        return isFullfiliable && !needsAuthentication
    }
}
