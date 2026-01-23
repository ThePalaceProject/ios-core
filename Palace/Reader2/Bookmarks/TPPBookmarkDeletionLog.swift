//
//  TPPBookmarkDeletionLog.swift
//  Palace
//
//  Track explicitly deleted bookmarks to ensure
//  they get deleted from the server during sync, regardless of device ID.
//

import Foundation

/// Tracks bookmarks that the user explicitly deleted locally.
/// This ensures that during sync, these bookmarks are deleted from the server
/// rather than being re-added to the local registry.
///
/// This solves the "ghost bookmark" problem where bookmarks from previous loans
/// or other devices cannot be deleted because the device ID doesn't match.
@objcMembers
final class TPPBookmarkDeletionLog: NSObject {
  
  static let shared = TPPBookmarkDeletionLog()
  
  private let userDefaultsKey = "TPPBookmarkDeletionLog"
  private let queue = DispatchQueue(label: "org.thepalaceproject.bookmarkDeletionLog", attributes: .concurrent)
  
  /// In-memory cache of pending deletions: [bookIdentifier: Set<annotationId>]
  private var deletionLog: [String: Set<String>] = [:]
  
  private override init() {
    super.init()
    loadFromDisk()
  }
  
  // MARK: - Public API
  
  /// Records that a bookmark was explicitly deleted by the user.
  /// This ensures the bookmark will be deleted from the server on next sync.
  /// - Parameters:
  ///   - annotationId: The server annotation ID of the deleted bookmark
  ///   - bookIdentifier: The identifier of the book
  func logDeletion(annotationId: String, forBook bookIdentifier: String) {
    guard !annotationId.isEmpty else { return }
    
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      var bookDeletions = self.deletionLog[bookIdentifier] ?? Set<String>()
      bookDeletions.insert(annotationId)
      self.deletionLog[bookIdentifier] = bookDeletions
      
      Log.debug(#file, "Logged bookmark deletion for sync: \(annotationId)")
      
      self.saveToDisk()
    }
  }
  
  /// Returns the set of annotation IDs that were explicitly deleted for a book.
  /// - Parameter bookIdentifier: The identifier of the book
  /// - Returns: Set of annotation IDs pending deletion from server
  func pendingDeletions(forBook bookIdentifier: String) -> Set<String> {
    var result = Set<String>()
    queue.sync {
      result = deletionLog[bookIdentifier] ?? Set<String>()
    }
    return result
  }
  
  /// Clears a deletion from the log after it has been successfully deleted from the server.
  /// - Parameters:
  ///   - annotationId: The annotation ID that was deleted
  ///   - bookIdentifier: The identifier of the book
  func clearDeletion(annotationId: String, forBook bookIdentifier: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      self.deletionLog[bookIdentifier]?.remove(annotationId)
      
      // Clean up empty entries
      if self.deletionLog[bookIdentifier]?.isEmpty == true {
        self.deletionLog.removeValue(forKey: bookIdentifier)
      }
      
      self.saveToDisk()
    }
  }
  
  /// Clears all pending deletions for a book.
  /// Called when a book is returned to reset state.
  /// - Parameter bookIdentifier: The identifier of the book
  func clearAllDeletions(forBook bookIdentifier: String) {
    queue.async(flags: .barrier) { [weak self] in
      guard let self = self else { return }
      
      self.deletionLog.removeValue(forKey: bookIdentifier)
      self.saveToDisk()
      
      Log.debug(#file, "Cleared all pending bookmark deletions for book: \(bookIdentifier)")
    }
  }
  
  // MARK: - Persistence
  
  private func saveToDisk() {
    // Convert Set to Array for JSON serialization
    let serializable = deletionLog.mapValues { Array($0) }
    
    if let data = try? JSONEncoder().encode(serializable) {
      UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
  }
  
  private func loadFromDisk() {
    guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
          let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
      return
    }
    
    // Convert Array back to Set
    deletionLog = decoded.mapValues { Set($0) }
  }
}
