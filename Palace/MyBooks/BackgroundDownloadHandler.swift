//
//  BackgroundDownloadHandler.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter to isolate URLSession background
//  download delegate methods and file operations into a focused type.
//

import Foundation
import PalaceLogging
import PalaceCatalog
import PalaceBookModel
import PalaceBookRegistry

// MARK: - BackgroundDownloadHandlerDelegate

/// Callback interface so the handler can delegate domain-specific actions
/// back to the download center facade.
protocol BackgroundDownloadHandlerDelegate: AnyObject {
    var stateManager: DownloadStateManager { get }
    var progressReporter: DownloadProgressReporter { get }
    var bookRegistry: TPPBookRegistryProvider { get }
    var userAccount: TPPUserAccount { get }
    /// Resolves a specific account by its captured id. PP-4978: follow-up work on
    /// a download must use the account the download STARTED under, which is not
    /// necessarily `userAccount` (the current one) after a library switch.
    /// `MyBooksDownloadCenter` already implements this — no new production code.
    func userAccount(forCapturedId capturedAccountId: String) -> TPPUserAccount
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
/// - Sendable invariant (Swift 6 `complete`-mode): the handler has exactly one
///   stored member, `weak var delegate`, assigned once at init (or via the
///   owner during construction) and never reassigned outside that window
///   (weak-ref reads + ARC zeroing are atomic). The `async` methods
///   (`handleDownloadProgress`, the OPDS-response handlers) touch only the
///   actor-serialized state reached *through* the delegate's `stateManager` and
///   local values, so awaiting them from a `@MainActor` caller does not race.
///   Mirrors the `DownloadStartCoordinator` / `DownloadTaskLifecycleService`
///   invariant. `@unchecked` only because the delegate existential is not
///   itself `Sendable`.
final class BackgroundDownloadHandler: NSObject, @unchecked Sendable {

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
        case ContentTypeOPDSPublication:
            // Intermediate type — will be handled by handleOPDS2PublicationResponse.
            return .none
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

    /// Checks if the MIME type indicates an OPDS 2 publication JSON response.
    /// Borrow endpoints sometimes redirect to a publication JSON whose
    /// fulfillment link is the actual content URL — see
    /// `handleOPDS2PublicationResponse`.
    func isOPDS2PublicationMimeType(_ mimeType: String) -> Bool {
        let lowercased = mimeType.lowercased()
        return lowercased.contains("opds-publication+json") ||
            lowercased.contains("opds+json")
    }

    /// Handles an OPDS 2 publication JSON response by parsing it and
    /// following the actual acquisition link. The borrow endpoint returns a
    /// publication JSON with fulfillment links — we parse it, extract the
    /// direct content link, and start a new download for the actual content.
    /// Returns `true` when a follow-up download was successfully started;
    /// the caller should treat that as success and stop processing the
    /// current task.
    func handleOPDS2PublicationResponse(
        at location: URL,
        for book: TPPBook,
        originalTask: URLSessionDownloadTask,
        session: URLSession
    ) async -> Bool {
        guard let jsonData = try? Data(contentsOf: location) else {
            Log.error(#file, "Failed to read OPDS2 publication JSON for \(book.identifier)")
            return false
        }

        // Parse the OPDS2 publication. The publication payload comes in two
        // shapes — `OPDS2Publication` (the lean form) and `OPDS2Full
        // Publication`. Try the lean form first; on decode failure fall back
        // to the full form before bailing out.
        if let publication = try? JSONDecoder().decode(OPDS2Publication.self, from: jsonData),
           let updatedBook = publication.toBook() {
            return await followAcquisitionLink(from: updatedBook, originalBook: book, originalTask: originalTask, session: session)
        }

        do {
            let fullPub = try JSONDecoder().decode(OPDS2FullPublication.self, from: jsonData)
            if let updatedBook = fullPub.toBook() {
                return await followAcquisitionLink(from: updatedBook, originalBook: book, originalTask: originalTask, session: session)
            }
        } catch {
            Log.error(#file, "Failed to decode OPDS2 publication JSON for \(book.identifier): \(error)")
        }
        return false
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
            } else if AppContainer.production().accountsManager.currentUserAccount.isTokenRefreshRequired() {
                // The DECISION still reads the current library's staleness. The
                // CREDENTIALS are correct — PP-4986 stamps this download's task in
                // `MyBooksDownloadCenter.persistStartedTaskRecord`, so the retry
                // rebuild authenticates as the library the download started under
                // regardless of what is selected now. This is a wrong-TRIGGER bug:
                // a refresh can fire for the wrong library's staleness, or fail to
                // fire for the right one's.
                //
                // (An earlier revision of this comment made that same claim BEFORE
                // the stamp existed, when it was false and this site still leaked.
                // It is true now because the download half landed, not because the
                // wording improved.)
                //
                // Fixing the trigger means redirecting to
                // `startedForAccount(for:delegate:)` at :296 — two lines — but the
                // arm is unreachable in a test while the refresh is read from
                // `AppContainer.production()` here, so it needs an injected seam
                // first. Deliberately deferred: the seam is a composition-root
                // change on a critical path, and the residual no longer leaks
                // credentials.
                NSLog("Authentication might be needed after all")
                AppContainer.production().networkExecutor.refreshTokenAndResume(task: task)
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
        guard let xmlData = try? Data(contentsOf: location) else {
            Log.error(#file, "Failed to read OPDS entry XML for \(book.identifier)")
            return false
        }

        guard let xml = TPPXML.xml(withData: xmlData), let entry = TPPOPDSEntry(xml: xml) else {
            Log.warn(#file, "Failed to parse XML as OPDS entry for \(book.identifier)")
            return false
        }

        guard let updatedBook = TPPBook(entry: entry) else {
            Log.warn(#file, "Failed to create book from OPDS entry for \(book.identifier)")
            return false
        }

        return await followAcquisitionLink(from: updatedBook, originalBook: book, originalTask: originalTask, session: session)
    }

    /// The account whose credentials a download's re-issued request should use —
    /// the account it was STARTED under, not whichever is current now.
    ///
    /// Resolved from the durable started-task record, keyed by book id.
    ///
    /// KNOWN BOUND on that record, stated because it is the premise this rests on:
    /// it is written at download start AND rewritten on each transfer-retry
    /// re-issue (`persistStartedTaskRecord`, called from `addDownloadTask` and
    /// from the retry path), and `DownloadTaskPersistence.record` upserts by book
    /// id. So a transfer retry that happens AFTER a library switch overwrites the
    /// captured account with the then-current one, and this resolver would then
    /// return that. It is a narrowing, not a guarantee: the record is the best
    /// available approximation of "the account this download started under", not a
    /// true capture of it. Closing that needs the retry to preserve the original
    /// account, which is out of scope here.
    ///
    /// Degrades to `delegate.userAccount` — today's
    /// behaviour — when there is no record or its account is empty, so this can
    /// only ever narrow the set of requests carrying the wrong library's
    /// credential via THOSE ARMS — never widen it. Scoped deliberately: the
    /// retry bound above admits one narrow widening sequence (start under A,
    /// switch to B, transient retry rewrites the record to B, switch back to A,
    /// re-issue then resolves B where today's current-account read would have
    /// resolved A). Two switches plus an intervening retry, against a defect
    /// that fires on one switch — strongly narrowing on net, but not an
    /// absolute. The start path writes
    /// `account: currentAccountID ?? ""`, so the empty case is real, not defensive.
    ///
    /// Same two-hop shape as the challenge-side resolver PP-4969 added; keyed by
    /// book rather than task because a re-issued task has no record of its own.
    ///
    /// Takes the delegate rather than reading `self.delegate`: every call site has
    /// already unwrapped it, so there is no nil arm to invent a fallback for — and
    /// the fallback an earlier draft used reached `AppContainer.production()` from
    /// a collaborator, which is the composition-root rule this project holds.
    func startedForAccount(for book: TPPBook, delegate: BackgroundDownloadHandlerDelegate) -> TPPUserAccount {
        guard let startedAccountID = delegate.stateManager
            .persistedRecords()
            .first(where: { $0.bookID == book.identifier })?
            .account,
            !startedAccountID.isEmpty
        else {
            return delegate.userAccount
        }
        return delegate.userAccount(forCapturedId: startedAccountID)
    }

    /// Shared follow-up step for both OPDS-entry XML and OPDS2 JSON publication
    /// paths. Given a book whose `defaultAcquisition` resolves to a direct
    /// content URL (not another opds-catalog), this swaps the original task
    /// out of stateManager, registers the updated book with `.downloading`,
    /// kicks off a new authenticated downloadTask, and returns true on success.
    func followAcquisitionLink(
        from updatedBook: TPPBook,
        originalBook: TPPBook,
        originalTask: URLSessionDownloadTask,
        session: URLSession
    ) async -> Bool {
        guard let delegate = delegate else { return false }
        let stateManager = delegate.stateManager
        let bookRegistry = delegate.bookRegistry

        guard let acquisition = updatedBook.defaultAcquisition,
              !acquisition.type.lowercased().contains("opds-catalog") else {
            Log.warn(#file, "No direct acquisition link for \(originalBook.identifier)")
            return false
        }

        let acquisitionURL = acquisition.hrefURL
        Log.info(#file, "Following acquisition link: \(acquisitionURL)")

        await stateManager.taskIdentifierToBook.remove(originalTask.taskIdentifier)

        let registryLocation = bookRegistry.location(forIdentifier: originalBook.identifier)
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
        // PP-4978: the account this download STARTED under. Keyed on
        // `originalBook` because the record was written under it at download start;
        // the follow-up may carry an updated book.
        if let token = startedForAccount(for: originalBook, delegate: delegate).authToken {
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

        // PP-5023: durably record the task this path starts. Until it did, the
        // task was invisible to launch reconciliation's contested-URL guard,
        // which is computed from persisted records alone — so another book whose
        // record named this same URL saw exactly one live task on it and adopted
        // THIS download, receiving a file for a title the patron never asked for.
        //
        // `inheritingFrom: originalBook` because the record was written under the
        // original at download start, and this re-registers under a book parsed
        // from the server's OPDS entry whose identifier can differ. Ordered before
        // the removal below so the account is read while the source record exists.
        stateManager.persistReissuedTask(
            bookID: updatedBook.identifier,
            taskIdentifier: newTask.taskIdentifier,
            downloadURL: acquisitionURL,
            inheritingFrom: originalBook.identifier,
            stampingAccountOn: newTask)

        if originalBook.identifier != updatedBook.identifier {
            // The superseded record names a task that no longer exists, under a
            // book no longer downloading under that id. Leaving it is not inert:
            // it is a record that can adopt some other book's live task on its
            // URL, which is this ticket's own defect pointed the other way.
            stateManager.removePersistedRecord(for: originalBook.identifier)
        }

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
            parentDir.excludeFromBackup()

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
