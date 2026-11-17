import Foundation
import PalaceLogging

/// Decides which local records a loans-feed sync removes. `BookRegistrySync.sync`
/// and the app's post-Return `syncAsync` both call it, so the two paths apply the
/// same guards (PP-5452).
// PUBLIC_INTENT: the app target's `TPPBookRegistry.syncAsync` calls it across the package boundary.
public enum LoansFeedReconciliation {

  /// - Parameters:
  ///   - localIdentifiers: the records held before the sync.
  ///   - feedIdentifiers: the books the feed listed and the app parsed.
  ///   - unparsedEntryIdentifiers: one element per feed entry the OPDS parser
  ///     rejected; nil when that entry has no readable `id`.
  ///   - sideloadedIdentifiers: books that never appear in a loans feed.
  /// - Returns: the records absent from the feed, or none when the feed has no
  ///   entries or a rejected entry cannot be matched to a record. In both cases
  ///   the feed does not show which loans ended.
  // PUBLIC_INTENT: called from the app target's `syncAsync`.
  public static func identifiersToRemove(
    localIdentifiers: Set<String>,
    feedIdentifiers: Set<String>,
    unparsedEntryIdentifiers: [String?],
    sideloadedIdentifiers: Set<String>
  ) -> Set<String> {
    let identifiedUnparsed = unparsedEntryIdentifiers.compactMap { $0 }
    if !identifiedUnparsed.isEmpty {
      Log.warn(#file, "Loans feed has \(identifiedUnparsed.count) entry(s) the app could not parse; keeping their records: \(identifiedUnparsed)")
    }

    let absent = localIdentifiers
      .subtracting(feedIdentifiers)
      .subtracting(sideloadedIdentifiers)
      .subtracting(identifiedUnparsed)
    guard !absent.isEmpty else { return [] }

    if identifiedUnparsed.count < unparsedEntryIdentifiers.count {
      Log.error(#file, "Loans feed has an entry with no readable id; keeping all \(absent.count) record(s) absent from the feed this sync")
      return []
    }

    let feedEntryCount = feedIdentifiers.count + unparsedEntryIdentifiers.count
    if BookRegistrySync.shouldSkipBulkDeletion(
      localCount: localIdentifiers.count,
      feedCount: feedEntryCount,
      deletionCount: absent.count
    ) {
      Log.error(#file, "Sync returned EMPTY feed but \(localIdentifiers.count) local books exist - skipping deletion (possible server issue)")
      return []
    }
    return absent
  }
}
