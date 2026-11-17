//
//  BookStateReading.swift
//  Palace
//
//  Read-side protocol for Palace's two book-state owners (see
//  `docs/architecture/state-management-doctrine.md`): `TPPBookRegistry` for
//  loans and `SideloadedBookRegistry` for side-loaded content. They own
//  disjoint identifier sets and never reconcile; each returns `.unregistered`
//  for an identifier it does not own. `TPPBookRegistry` answers the same
//  question through `TPPBookRegistryProvider.state(for:)`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceBookModel
import PalaceBookRegistry

/// The one read question both authorized book-state owners answer, each over
/// its own (disjoint) identifier set. See the file header + the state-management
/// doctrine for why there are exactly two conformers.
protocol BookStateReading: AnyObject {
  /// The state the *authoritative owner* reports for `bookIdentifier`. An owner
  /// returns `.unregistered` for an identifier it does not own — it never
  /// speaks for the other owner's books, and the two owners never reconcile.
  func state(for bookIdentifier: String?) -> TPPBookState
}

// `SideloadedBookRegistry.state(for:)` is implemented in the registry's own file.
extension SideloadedBookRegistry: BookStateReading {}
