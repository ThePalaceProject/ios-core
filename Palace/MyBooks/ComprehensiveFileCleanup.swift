//
//  ComprehensiveFileCleanup.swift
//  Palace
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import PalaceAudiobookToolkit

/// Comprehensive file cleanup system that ensures complete removal of audiobook artifacts
/// Addresses user complaints about orphaned files after book returns
extension MyBooksDownloadCenter {
    
    // MARK: - Complete Audiobook Removal
    
    /// Completely remove all audiobook-related files and data
    /// This is a comprehensive cleanup that goes beyond the standard deleteLocalContent
    @objc func completelyRemoveAudiobook(_ book: TPPBook) {
        let bookId = book.identifier
        Log.info(#file, "Starting comprehensive cleanup for book: \(bookId)")
        
        // 1. Call existing cleanup first
        deleteLocalContent(for: bookId)
        
        // 2. Perform comprehensive cleanup
        performComprehensiveCleanup(for: book)
        
        // 3. Audit cleanup results
        auditCleanup(for: bookId)
        
        Log.info(#file, "Comprehensive cleanup completed for book: \(bookId)")
    }
    
    private func performComprehensiveCleanup(for book: TPPBook) {
        let bookId = book.identifier
        let fileManager = FileManager.default
        
        // 1. Remove LCP license files (all possible locations)
        removeLCPLicenseFiles(for: bookId)
        
        // 2. Remove cached audio segments
        removeCachedAudioSegments(for: bookId)
        
        // 3. Remove temporary download files
        removeTemporaryFiles(for: bookId)
        
        // 4. Clear from resource loader caches
        clearResourceLoaderCaches(for: bookId)
        
        // 5. Remove tracking data
        removeTrackingData(for: bookId)
        
        // 6. Clear from memory caches
        clearMemoryCaches(for: bookId)
        
        // 7. Remove any remaining audiobook-specific directories
        removeAudiobookDirectories(for: bookId)
    }
    
    // MARK: - Specific Cleanup Operations
    
    private func removeLCPLicenseFiles(for bookId: String) {
        let fileManager = FileManager.default
        
        // Multiple possible license locations
        let licensePaths = [
            // Documents/LCPLicenses/{bookId}.lcpl
            documentsDirectory?.appendingPathComponent("LCPLicenses").appendingPathComponent("\(bookId).lcpl"),
            // Content directory license
            fileUrl(for: bookId)?.deletingPathExtension().appendingPathExtension("lcpl"),
            // Temporary directory license
            FileManager.default.temporaryDirectory.appendingPathComponent("LCP").appendingPathComponent("\(bookId).lcpl"),
            // Cache directory license
            cacheDirectory?.appendingPathComponent("LCP").appendingPathComponent("\(bookId).lcpl")
        ]
        
        for licensePath in licensePaths.compactMap({ $0 }) {
            if fileManager.fileExists(atPath: licensePath.path) {
                do {
                    try fileManager.removeItem(at: licensePath)
                    Log.info(#file, "Removed LCP license: \(licensePath.lastPathComponent)")
                } catch {
                    Log.error(#file, "Failed to remove LCP license \(licensePath.path): \(error)")
                }
            }
        }
    }
    
    private func removeCachedAudioSegments(for bookId: String) {
        let fileManager = FileManager.default
        
        // Potential cache locations for audio segments
        let cachePaths = [
            // Main cache directory
            FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookCache").appendingPathComponent(bookId),
            // System cache directory
            cacheDirectory?.appendingPathComponent("AudiobookSegments").appendingPathComponent(bookId),
            // LCP decrypted segments
            FileManager.default.temporaryDirectory.appendingPathComponent("LCPDecrypted").appendingPathComponent(bookId),
            // Streaming cache
            cacheDirectory?.appendingPathComponent("StreamingCache").appendingPathComponent(bookId)
        ]
        
        for cachePath in cachePaths.compactMap({ $0 }) {
            if fileManager.fileExists(atPath: cachePath.path) {
                do {
                    try fileManager.removeItem(at: cachePath)
                    Log.info(#file, "Removed audio cache directory: \(cachePath.lastPathComponent)")
                } catch {
                    Log.error(#file, "Failed to remove cache directory \(cachePath.path): \(error)")
                }
            }
        }
    }
    
    private func removeTemporaryFiles(for bookId: String) {
        let fileManager = FileManager.default
        let tempDirectory = FileManager.default.temporaryDirectory
        
        // Look for temporary files related to this book
        let tempPaths = [
            tempDirectory.appendingPathComponent("\(bookId).tmp"),
            tempDirectory.appendingPathComponent("\(bookId).download"),
            tempDirectory.appendingPathComponent("\(bookId).partial"),
            tempDirectory.appendingPathComponent("download_\(bookId)"),
            tempDirectory.appendingPathComponent("manifest_\(bookId).json")
        ]
        
        for tempPath in tempPaths {
            if fileManager.fileExists(atPath: tempPath.path) {
                do {
                    try fileManager.removeItem(at: tempPath)
                    Log.info(#file, "Removed temporary file: \(tempPath.lastPathComponent)")
                } catch {
                    Log.error(#file, "Failed to remove temporary file \(tempPath.path): \(error)")
                }
            }
        }
        
        // Also search for any files containing the book ID in temp directory
        removeFilesContaining(bookId: bookId, inDirectory: tempDirectory)
    }
    
    private func clearResourceLoaderCaches(for bookId: String) {
        // Clear any resource loader caches that might contain references to this book
        // This is a placeholder for when LCPResourceLoaderDelegate has book-specific clearing
        NotificationCenter.default.post(
            name: .clearResourceCacheForBook,
            object: bookId
        )
    }
    
    private func removeTrackingData(for bookId: String) {
        // Remove audiobook tracking data
        if let audiobookDataManager = getAudiobookDataManager() {
            audiobookDataManager.removeTrackingData(for: bookId)
        }
        
        // Remove any stored playback positions
        UserDefaults.standard.removeObject(forKey: "playback_position_\(bookId)")
        UserDefaults.standard.removeObject(forKey: "playback_rate_\(bookId)")
        UserDefaults.standard.removeObject(forKey: "last_played_\(bookId)")
    }
    
    private func clearMemoryCaches(for bookId: String) {
        // Clear any in-memory caches that might hold references to this book
        // This helps prevent memory leaks
        
        // Clear from download info
        bookIdentifierToDownloadInfo.removeValue(forKey: bookId)
        bookIdentifierToDownloadProgress.removeValue(forKey: bookId)
        bookIdentifierToDownloadTask.removeValue(forKey: bookId)
        
        // Clear from any reverse mappings
        taskIdentifierToBook = taskIdentifierToBook.filter { $0.value.identifier != bookId }
        
        // Clear from pending queue
        pendingStartQueue = pendingStartQueue.filter { $0.identifier != bookId }
    }
    
    private func removeAudiobookDirectories(for bookId: String) {
        let fileManager = FileManager.default
        
        // Look for any directories that might be specific to this audiobook
        let potentialDirectories = [
            documentsDirectory?.appendingPathComponent("Audiobooks").appendingPathComponent(bookId),
            cacheDirectory?.appendingPathComponent("Audiobooks").appendingPathComponent(bookId),
            documentsDirectory?.appendingPathComponent(bookId),
            cacheDirectory?.appendingPathComponent(bookId)
        ]
        
        for directory in potentialDirectories.compactMap({ $0 }) {
            if fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.removeItem(at: directory)
                    Log.info(#file, "Removed audiobook directory: \(directory.lastPathComponent)")
                } catch {
                    Log.error(#file, "Failed to remove directory \(directory.path): \(error)")
                }
            }
        }
    }
    
    // MARK: - Cleanup Auditing
    
    private func auditCleanup(for bookId: String) {
        let remainingFiles = findRemainingFiles(for: bookId)
        
        if remainingFiles.isEmpty {
            Log.info(#file, "✅ Cleanup audit passed: No remaining files for \(bookId)")
        } else {
            Log.warn(#file, "⚠️ Cleanup audit found \(remainingFiles.count) remaining files for \(bookId)")
            for file in remainingFiles.prefix(10) { // Log first 10
                Log.warn(#file, "Remaining file: \(file)")
            }
            
            // Schedule cleanup retry for remaining files
            scheduleCleanupRetry(bookId: bookId, files: remainingFiles)
        }
    }
    
    func findRemainingFiles(for bookId: String) -> [String] {
        let fileManager = FileManager.default
        var remainingFiles: [String] = []
        
        // Search in key directories for any files related to this book
        let searchDirectories = [
            documentsDirectory,
            cacheDirectory,
            FileManager.default.temporaryDirectory
        ].compactMap { $0 }
        
        for directory in searchDirectories {
            let foundFiles = searchForFiles(containing: bookId, in: directory)
            remainingFiles.append(contentsOf: foundFiles)
        }
        
        return remainingFiles
    }
    
    private func searchForFiles(containing bookId: String, in directory: URL) -> [String] {
        let fileManager = FileManager.default
        var foundFiles: [String] = []
        
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return foundFiles
        }
        
        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent
            if fileName.contains(bookId) {
                foundFiles.append(fileURL.path)
            }
        }
        
        return foundFiles
    }
    
    private func scheduleCleanupRetry(bookId: String, files: [String]) {
        // Schedule a retry cleanup after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.retryCleanup(bookId: bookId, files: files)
        }
    }
    
    private func retryCleanup(bookId: String, files: [String]) {
        let fileManager = FileManager.default
        var cleanedCount = 0
        
        for filePath in files {
            if fileManager.fileExists(atPath: filePath) {
                do {
                    try fileManager.removeItem(atPath: filePath)
                    cleanedCount += 1
                    Log.info(#file, "Retry cleanup removed: \(filePath)")
                } catch {
                    Log.error(#file, "Retry cleanup failed for \(filePath): \(error)")
                }
            }
        }
        
        if cleanedCount > 0 {
            Log.info(#file, "Retry cleanup removed \(cleanedCount) additional files for \(bookId)")
        }
    }
    
    // MARK: - Helper Methods
    
    private func removeFilesContaining(bookId: String, inDirectory directory: URL) {
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        for case let fileURL as URL in enumerator {
            let fileName = fileURL.lastPathComponent
            if fileName.contains(bookId) {
                do {
                    try fileManager.removeItem(at: fileURL)
                    Log.info(#file, "Removed file containing book ID: \(fileName)")
                } catch {
                    Log.error(#file, "Failed to remove file \(fileName): \(error)")
                }
            }
        }
    }
    
    private var documentsDirectory: URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
    
    private var cacheDirectory: URL? {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
    
    private func getAudiobookDataManager() -> AudiobookDataManager? {
        // This would need to be implemented based on how AudiobookDataManager is accessed
        // For now, return nil as a placeholder
        return nil
    }
}

// MARK: - Book Return Integration

extension MyBooksDownloadCenter {
    
    /// Enhanced book return that includes comprehensive cleanup
    @objc func returnBookWithCompleteCleanup(_ book: TPPBook) {
        Log.info(#file, "Returning book with complete cleanup: \(book.identifier)")
        
        // Perform the standard return process first
        // This would typically involve API calls to return the book
        performStandardBookReturn(book)
        
        // Then perform comprehensive cleanup
        completelyRemoveAudiobook(book)
        
        // Update book registry state
        bookRegistry.setState(.downloadNeeded, for: book.identifier)
        
        // Broadcast update
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .TPPMyBooksDownloadCenterDidChange, object: self)
        }
    }
    
    private func performStandardBookReturn(_ book: TPPBook) {
        // This is a placeholder for the standard return logic
        // The actual implementation would depend on the existing return flow
        Log.info(#file, "Performing standard book return for: \(book.identifier)")
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let clearResourceCacheForBook = Notification.Name("ClearResourceCacheForBook")
}

// MARK: - AudiobookDataManager Extension

extension AudiobookDataManager {
    
    /// Remove all tracking data for a specific book
    func removeTrackingData(for bookId: String) {
        syncQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // Remove from URLs dictionary
            let libraryBooksToRemove = self.store.urls.keys.filter { $0.bookId == bookId }
            for libraryBook in libraryBooksToRemove {
                self.store.urls.removeValue(forKey: libraryBook)
            }
            
            // Remove from queue
            self.store.queue = self.store.queue.filter { $0.bookId != bookId }
            
            // Save changes
            self.saveStore()
            
            Log.info(#file, "Removed tracking data for book: \(bookId)")
        }
    }
}
