//
//  RegistryPositionPersistence.swift
//  PalaceBookRegistry
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// PUBLIC_INTENT: parameter type of the public setLocation(_:forIdentifier:persistence:), which the app target calls.
/// When a reading-position change reaches the registry file.
///
/// Both modes update the in-memory record on every call, so bookmarks, the
/// position synchroniser and a reopened reader always read the newest position.
public enum RegistryPositionPersistence: Sendable, Equatable {
  /// Write the registry file on every call. Audiobooks, PDFs and the server
  /// position sync use this.
  case immediate
  /// Write the registry file at most once per `BookmarkManager.coalescedPositionWriteInterval`
  /// for each book. A change inside that interval is kept as pending and written
  /// by the next due call or by `flushPendingPositions()`. Used by the EPUB
  /// reader, which reports a position on every page turn (PP-5507).
  case coalesced
}
