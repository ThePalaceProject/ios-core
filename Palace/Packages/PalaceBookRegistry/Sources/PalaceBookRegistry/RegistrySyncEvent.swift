//
//  RegistrySyncEvent.swift
//  PalaceBookRegistry
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// One event on `TPPBookRegistryProvider.syncEventPublisher`.
// PUBLIC_INTENT: element type of the public provider protocol's syncEventPublisher; app-target view models switch over it across the package boundary.
public enum RegistrySyncEvent: Equatable, Sendable {
    /// The registry started syncing with the server.
    case began
    /// The registry stopped syncing, whether or not the sync succeeded.
    case ended
    /// A sync failed. `detail` is the text a patron can be shown: the error
    /// document's `detail` string when present, else its `title`; nil when that
    /// text is missing or empty. Only the text is carried, so the event stays
    /// `Sendable`.
    case failed(detail: String?)
}
