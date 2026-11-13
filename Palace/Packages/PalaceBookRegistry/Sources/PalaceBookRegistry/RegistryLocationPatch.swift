//
//  RegistryLocationPatch.swift
//  PalaceBookRegistry
//
//  Sets one book's location in the registry file of a library whose shelf is
//  not in memory (PP-5578).
//

import Foundation
import PalaceLogging
import PalaceBookModel

/// Rewrites one record's location in `registry.json` and changes nothing else:
/// no state reconciliation, no backup, no recovery work. Those belong to that
/// library's own load. Nothing is written when the file is not a valid
/// registry or does not hold the book. The rewrite makes the library's
/// per-book files untrusted, so its next load reads this file
/// (docs/architecture/per-book-registry-storage.md).
enum RegistryLocationPatch {
  /// Runs on the registry's disk-write queue, after any save already queued.
  static func write(
    _ location: TPPBookLocation?,
    forIdentifier identifier: String,
    registryURL url: URL,
    beforeWrite: (RegistryWriteStep, URL) throws -> Void
  ) {
    let locationKey = TPPBookRegistryKey.location.rawValue
    guard case .valid(var records) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)),
          let index = records.firstIndex(where: {
            ($0[TPPBookRegistryKey.book.rawValue] as? [String: Any])?["id"] as? String == identifier
          })
    else {
      Log.info(#file, "Position not saved: \(identifier) is not in the registry file of its library")
      return
    }
    if let location {
      records[index][locationKey] = location.dictionaryRepresentation
    } else {
      records[index].removeValue(forKey: locationKey)
    }
    let payload: [String: Any] = [
      RegistryFileRecovery.schemaVersionKey: RegistryFileRecovery.currentSchemaVersion,
      TPPBookRegistryKey.records.rawValue: records
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed)
      try beforeWrite(.primary, url)
      try data.write(to: url, options: .atomic)
    } catch {
      Log.error(#file, "Error writing a position to another library's registry: \(error.localizedDescription)")
    }
  }
}
