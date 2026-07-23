//
//  BookStateReading.swift
//  Palace
//
//  Read-side seam shared by Palace's TWO authorized book-state owners
//  (swarm swarm_8ce6f5ae · Contract D). Formalizes the "single source of truth
//  — scoped, not absolute" clause of
//  `docs/architecture/state-management-doctrine.md`.
//
//  The doctrine declares `TPPBookRegistry` the single source of truth for book
//  state *scoped to loans*, and `SideloadedBookRegistry` a documented,
//  probe-guarded SECOND owner scoped to side-loaded (non-loan) content. Both
//  owners answer exactly one read question — "what state is this identifier in,
//  according to the owner authoritative for it?" — so both are viewed through
//  this one seam. Callers depend on `BookStateReading`, not the concrete class.
//
//  The two owners answer over DISJOINT identifier sets (loaned vs side-loaded)
//  and never reconcile against each other: each returns `.unregistered` for an
//  identifier it does not own, so neither ever speaks for the other's books.
//
//  Authorized conformers — and ONLY these two (a Contract-F probe guards the
//  owner count so a third cannot appear silently):
//    • `TPPBookRegistry`        — loans-scoped owner. It already exposes
//      `state(for:)` via `TPPBookRegistryProvider`; its conformance to THIS
//      seam is declared by Contract C, whose file is off-limits to Contract D.
//      Declaring it here would risk a cross-contract collision, so Contract D
//      conforms only the side-load owner and documents the loan owner.
//    • `SideloadedBookRegistry` — side-load-scoped owner (conformed below).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// The one read question both authorized book-state owners answer, each over
/// its own (disjoint) identifier set. See the file header + the state-management
/// doctrine for why there are exactly two conformers.
protocol BookStateReading: AnyObject {
  /// The state the *authoritative owner* reports for `bookIdentifier`. An owner
  /// returns `.unregistered` for an identifier it does not own — it never
  /// speaks for the other owner's books, and the two owners never reconcile.
  func state(for bookIdentifier: String?) -> TPPBookState
}

// `SideloadedBookRegistry.state(for:)` lives in the registry's own file
// (Contract D scope); this conformance is a no-op declaration of the seam.
extension SideloadedBookRegistry: BookStateReading {}
