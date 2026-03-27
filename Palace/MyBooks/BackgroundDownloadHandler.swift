//
//  BackgroundDownloadHandler.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter to isolate URLSession background
//  download delegate methods and file operations into a focused type.
//

import Foundation

// MARK: - BackgroundDownloadHandlerDelegate

/// Callback interface so the handler can delegate domain-specific actions
/// back to the download center facade.
protocol BackgroundDownloadHandlerDelegate: AnyObject {
    var stateManager: DownloadStateManager { get }
    var progressReporter: DownloadProgressReporter { get }
    var bookRegistry: TPPBookRegistryProvider { get }
    var userAccount: TPPUserAccount { get }
    var tokenInterceptor: TokenRefreshInterceptor { get }

    func handleDownloadCompletion(session: URLSession, task: URLSessionDownloadTask, location: URL) async
    func handleTaskCompletionError(task: URLSessionTask, error: Error?) async
    func schedulePendingStartsIfPossible()
    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?)
    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook)
    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?)
    func fileUrl(for identifier: String) -> URL?
    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask)
}

// MARK: - BackgroundDownloadHandler

/// Handles URLSession background download delegate callbacks and file operations:
/// - Progress updates and MIME type detection
/// - OPDS entry response parsing
/// - File move/replace/validation after download
final class BackgroundDownloadHandler: NSObject {

    // MARK: - Properties

    weak var delegate: BackgroundDownloadHandlerDelegate?

    // MARK: - Init

    init(delegate: BackgroundDownloadHandlerDelegate? = nil) {
        self.delegate = delegate
        super.init()
    }

    // MARK: - MIME Type Detection

    func detectRightsManagement(from mimeType: String) -> MyBooksDownloadInfo.MyBooksDownloadRightsManagement {
        switch mimeType {
        case ContentTypeAdobeAdept:
            return .adobe
        case ContentTypeReadiumLCP:
            return .lcp
        case ContentTypeEpubZip:
            return .none
        case ContentTypeBearerToken:
            return .simplifiedBearerTokenJSON
        #if FEATURE_OVERDRIVE
        case "application/json":
            return .overdriveManifestJSON
        #endif
        default:
            if TPPOPDSAcquisitionPath.supportedTypes().contains(mimeType) {
                NSLog("Presuming no DRM for unrecognized MIME type \"\(mimeType)\".")
                return .none
            }
            return .unknown
        }
    }

    /// Checks if the MIME type indicates an OPDS entry response
    func isOPDSEntryMimeType(_ mimeType: String) -> Bool {
        let lowercased = mimeType.lowercased()
        return lowercased == "application/xml" ||
            lowercased == "text/xml" ||
            lowercased.contains("atom+xml") ||
            lowercased.contains("opds-catalog")
    }

    // MARK: - Progress Handling

    func handleDownloadProgress(
        for book: TPPBook,
        task: URLSessionDownloadTask,
        bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) async {
        guard let delegate = delegate else { return }
        let stateManager = delegate.stateManager
        let progressReporter = delegate.progressReporter

        if bytesWritten == totalBytesWritten {
            guard let mimeType = task.response?.mimeType else {
                Log.error(#file, "No MIME type in response for book: \(book.identifier)")
                return
            }

            Log.info(#file, "Download MIME type detected for \(book.identifier): \(mimeType)")

            let detectedRights = detectRightsManagement(from: mimeType)

            if detectedRights != .unknown {
                if let info = await stateManager.downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(detectedRights) {
                    await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
                }
            } else if TPPUserAccount.sharedAccount().isTokenRefreshRequired() {
                NSLog("Authentication might be needed after all")
                TPPNetworkExecutor.shared.refreshTokenAndResume(task: task)
                return
            }
        }

        let rightsManagement = await stateManager.downloadInfoAsync(forBookIdentifier: book.identifier)?.rightsManagement ?? .none
        if rightsManagement != .adobe && rightsManagement != .simplifiedBearerTokenJSON && rightsManagement != .overdriveManifestJSON {
            if totalBytesExpectedToWrite > 0 {
                let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                if let info = await stateManager.downloadInfoAsync(forBookIdentifier: book.identifier)?.withDownloadProgress(progress) {
                    await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
                }

                progressReporter.sendProgress(bookIdentifier: book.identifier, progress: progress)
                progressReporter.announceDownloadProgress(for: book, progress: progress)

                if progress > 0.95 || Int(progress * 100) % 20 == 0 {
                    progressReporter.broadcastUpdate()
                }
            }
        }
    }

    // MARK: - OPDS Entry Handling

    func handleOPDSEntryResponse(
        at location: URL,
        for book: TPPBook,
        originalTask: URLSessionDownloadTask,
        session: URLSession
    ) async -> Bool {
        guard let delegate = delegate else { return false }
        let stateManager = delegate.stateManager
        let bookRegistry = delegate.bookRegistry

        guard let xmlData = try? Data(contentsOf: location) else {
            Log.error(#file, "Failed to read OPDS entry XML for \(book.identifier)")
            return false
        }

        guard let entry = TPPOPDSEntry(xml: TPPXML(data: xmlData)) else {
            Log.warn(#file, "Failed to parse XML as OPDS entry for \(book.identifier)")
            return false
        }

        guard let updatedBook = TPPBook(entry: entry) else {
            Log.warn(#file, "Failed to create book from OPDS entry for \(book.identifier)")
            return false
        }

        guard let acquisition = updatedBook.defaultAcquisition,
              !acquisition.type.lowercased().contains("opds-catalog") else {
            Log.warn(#file, "No direct acquisition link in OPDS entry for \(book.identifier)")
            return false
        }

        let acquisitionURL = acquisition.hrefURL
        Log.info(#file, "Following acquisition link from OPDS entry: \(acquisitionURL)")

        await stateManager.taskIdentifierToBook.remove(originalTask.taskIdentifier)

        let registryLocation = bookRegistry.location(forIdentifier: book.identifier)
        bookRegistry.addBook(
            updatedBook,
            location: registryLocation,
            state: .downloading,
            fulfillmentId: nil as String?,
            readiumBookmarks: nil as [TPPReadiumBookmark]?,
            genericBookmarks: nil as [TPPBookLocation]?
        )

        let newRights = detectRightsManagement(from: acquisition.type)

        var request = URLRequest(url: acquisitionURL, applyingCustomUserAgent: true)
        if let token = TPPUserAccount.sharedAccount().authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let newTask = session.downloadTask(with: request)
        let downloadInfo = MyBooksDownloadInfo(
            downloadProgress: 0.0,
            downloadTask: newTask,
            rightsManagement: newRights
        )

        await stateManager.bookIdentifierToDownloadInfo.set(updatedBook.identifier, value: downloadInfo)
        await stateManager.taskIdentifierToBook.set(newTask.taskIdentifier, value: updatedBook)

        newTask.resume()
        Log.info(#file, "Started follow-up download task \(newTask.taskIdentifier) for \(updatedBook.identifier)")
        return true
    }

    // MARK: - File Operations

    func moveFile(at sourceLocation: URL, toDestinationForBook book: TPPBook, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        guard let delegate = delegate else { return false }
        var removeError: Error?
        var moveError: Error?

        guard let finalFileURL = delegate.fileUrl(for: book.identifier) else { return false }

        do {
            try FileManager.default.removeItem(at: finalFileURL)
        } catch {
            removeError = error
        }

        var success = false

        do {
            try FileManager.default.moveItem(at: sourceLocation, to: finalFileURL)
            success = true
        } catch {
            moveError = error
        }

        if success {
            if validateDownloadedFile(at: finalFileURL, for: book) {
                delegate.bookRegistry.setState(.downloadSuccessful, for: book.identifier)
                delegate.progressReporter.announceDownloadCompleted(for: book)
            } else {
                delegate.logBookDownloadFailure(book, reason: "File validation failed after move", downloadTask: downloadTask, metadata: [
                    "finalFileURL": finalFileURL.absoluteString
                ])
                success = false
            }
        } else if let moveError = moveError {
            delegate.logBookDownloadFailure(book, reason: "Couldn't move book to final disk location", downloadTask: downloadTask, metadata: [
                "moveError": moveError,
                "removeError": removeError?.localizedDescription ?? "N/A",
                "sourceLocation": sourceLocation.absoluteString,
                "finalFileURL": finalFileURL.absoluteString
            ])
        }

        return success
    }

    func replaceBook(_ book: TPPBook, withFileAtURL sourceLocation: URL, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
        guard let delegate = delegate else { return false }
        guard let destURL = delegate.fileUrl(for: book.identifier) else { return false }

        let fileManager = FileManager.default

        do {
            let parentDir = destURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parentDir.path) {
                try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            if fileManager.fileExists(atPath: destURL.path) {
                _ = try fileManager.replaceItemAt(destURL, withItemAt: sourceLocation, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: sourceLocation, to: destURL)
            }

            guard validateDownloadedFile(at: destURL, for: book) else {
                Log.error(#file, "File validation failed after replace/move for '\(book.title)'")
                return false
            }

            #if LCP
            let isLCPAudiobook = book.defaultBookContentType == .audiobook && LCPAudiobooks.canOpenBook(book)
            if !isLCPAudiobook {
                delegate.bookRegistry.setState(.downloadSuccessful, for: book.identifier)
                delegate.progressReporter.announceDownloadCompleted(for: book)
            }
            #else
            delegate.bookRegistry.setState(.downloadSuccessful, for: book.identifier)
            delegate.progressReporter.announceDownloadCompleted(for: book)
            #endif
            return true
        } catch {
            delegate.logBookDownloadFailure(book,
                                   reason: "Couldn't replace/move downloaded book",
                                   downloadTask: downloadTask,
                                   metadata: [
                                    "error": error,
                                    "destinationFileURL": destURL as Any,
                                    "sourceFileURL": sourceLocation as Any,
                                    "destinationExists": fileManager.fileExists(atPath: destURL.path)
                                   ])
        }

        return false
    }

    func validateDownloadedFile(at fileURL: URL, for book: TPPBook) -> Bool {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: fileURL.path) else {
            Log.error(#file, "Downloaded file missing at \(fileURL.path) for '\(book.title)'")
            return false
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard let fileSize = attributes[.size] as? Int, fileSize > 0 else {
                Log.error(#file, "Downloaded file is empty at \(fileURL.path) for '\(book.title)'")
                return false
            }

            Log.debug(#file, "Downloaded file validated: \(fileURL.lastPathComponent) (\(fileSize) bytes)")
            return true
        } catch {
            Log.error(#file, "Failed to get file attributes at \(fileURL.path): \(error)")
            return false
        }
    }
}
