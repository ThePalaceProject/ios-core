//
//  RightsManagementDispatcher.swift
//  Palace
//
//  Owns the per-rights-management dispatch step that lived inside
//  MyBooksDownloadCenter as the second half of
//  `handleDownloadCompletion(session:task:location:)`. Receives the
//  parsed rights (from DownloadCompletionParser) and routes:
//
//    - `.unknown` — log + flag failure.
//    - `.adobe` (#if FEATURE_DRM_CONNECTOR) — detect Adobe-PDF
//      payloads (unsupported), otherwise kick off ensureDeviceActivated
//      + adobeDRMService.fulfill(...) on a fire-and-forget Task.
//    - `.lcp` — delegate to MBDC's fulfillLCPLicense.
//    - `.simplifiedBearerTokenJSON` — parse bearer-token JSON,
//      register a new download task with the Authorization header,
//      and resume() it.
//    - `.overdriveManifestJSON` — backgroundDownloadHandler.replaceBook.
//    - `.none` — backgroundDownloadHandler.moveFile.
//
//  Returns a `RightsManagementDispatchResult` carrying the updated
//  failureRequiringAlert + failureError so the consumer can hand
//  off to the existing auth-retry / alert tail unchanged.
//

import Foundation
import PalaceCatalog
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - File-ops surface

/// Subset of `BackgroundDownloadHandler` the dispatcher reaches for
/// in the .overdriveManifestJSON and .none cases. Tests stub this.
protocol BackgroundDownloadFileOps: AnyObject {
    func replaceBook(_ book: TPPBook, withFileAtURL sourceLocation: URL, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool
    func moveFile(at sourceLocation: URL, toDestinationForBook book: TPPBook, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool
}

extension BackgroundDownloadHandler: BackgroundDownloadFileOps {}

// MARK: - Delegate

/// MBDC-side callbacks the dispatcher invokes for cases that need to
/// touch UI / logging / LCP fulfillment surfaces MBDC owns.
protocol RightsManagementDispatcherDelegate: AnyObject {
    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?)
    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask)
    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?)
    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook)
}

// MARK: - Result

struct RightsManagementDispatchResult {
    let failureRequiringAlert: Bool
    let failureError: Error?

    /// True when this dispatch started a NEW download task that is still running
    /// — today only the bearer-token hop, which swaps the fulfilment task for a
    /// content task against the bearer location.
    ///
    /// The caller's terminal cleanup runs `removePersistedRecord`, which would
    /// delete the durable record for a download that has only just begun (PP-5023:
    /// the record was written and removed roughly 100ms later, leaving the bearer
    /// content transfer invisible to launch reconciliation exactly as before the
    /// fix). The OPDS follow-up avoids this by returning `.followUpStarted` from
    /// the parser and early-returning before the cleanup; the bearer hop happens
    /// inside dispatch, after that decision point, so it reports the same fact
    /// here instead.
    let followUpTaskInFlight: Bool

    init(failureRequiringAlert: Bool, failureError: Error?, followUpTaskInFlight: Bool = false) {
        self.failureRequiringAlert = failureRequiringAlert
        self.failureError = failureError
        self.followUpTaskInFlight = followUpTaskInFlight
    }
}

// MARK: - RightsManagementDispatcher

// @unchecked Sendable invariant: every stored dependency is a `let`
// (immutable after init). The only mutable member is `weak var delegate`,
// which is wired exactly once by MyBooksDownloadCenter during its own
// construction (`self.rightsDispatcher.delegate = self`) on the main thread and
// never reassigned. It is read from both `MainActor.run` hops and the
// nonisolated `dispatch(...)` body, but `weak var` loads / ARC-zeroing are
// runtime-serialized via the side-table lock, so reading it off-main is
// memory-safe. No stored value is mutated after init, so the class is safe to
// share across the Adobe fulfillment Task's concurrency boundary.
final class RightsManagementDispatcher: @unchecked Sendable {

    weak var delegate: RightsManagementDispatcherDelegate?

    private let stateManager: DownloadStateManager
    private let fileOps: BackgroundDownloadFileOps
    private let bookRegistry: TPPBookRegistryProvider
    private let userAccountProvider: () -> TPPUserAccount
    #if FEATURE_DRM_CONNECTOR
    private let adobeDRMService: AdobeDRMService
    #endif

    #if FEATURE_DRM_CONNECTOR
    init(
        stateManager: DownloadStateManager,
        fileOps: BackgroundDownloadFileOps,
        bookRegistry: TPPBookRegistryProvider,
        userAccountProvider: @escaping () -> TPPUserAccount,
        adobeDRMService: AdobeDRMService
    ) {
        self.stateManager = stateManager
        self.fileOps = fileOps
        self.bookRegistry = bookRegistry
        self.userAccountProvider = userAccountProvider
        self.adobeDRMService = adobeDRMService
    }
    #else
    init(
        stateManager: DownloadStateManager,
        fileOps: BackgroundDownloadFileOps,
        bookRegistry: TPPBookRegistryProvider,
        userAccountProvider: @escaping () -> TPPUserAccount
    ) {
        self.stateManager = stateManager
        self.fileOps = fileOps
        self.bookRegistry = bookRegistry
        self.userAccountProvider = userAccountProvider
    }
    #endif

    func dispatch(
        book: TPPBook,
        task: URLSessionDownloadTask,
        location: URL,
        session: URLSession,
        rights: MyBooksDownloadInfo.MyBooksDownloadRightsManagement,
        failureError: Error?
    ) async -> RightsManagementDispatchResult {
        var failureRequiringAlert = false
        var updatedFailureError = failureError
        // Set only by the bearer-token hop, which leaves a live content task
        // behind. Tells the caller not to run its terminal cleanup's durable-record
        // removal on a download that has just started. See the property's note.
        var followUpTaskInFlight = false

        switch rights {
        case .unknown:
            Log.error(#file, "❌ Rights management is unknown for book: \(book.identifier) - LCP fulfillment will NOT be called")
            delegate?.logBookDownloadFailure(book, reason: "Unknown rights management", downloadTask: task, metadata: nil)
            failureRequiringAlert = true

        case .adobe:
            #if FEATURE_DRM_CONNECTOR
            if let acsmData = try? Data(contentsOf: location),
               let acsmString = String(data: acsmData, encoding: .utf8),
               acsmString.contains(">application/pdf</dc:format>") {
                let msg = NSLocalizedString("\(book.title) is an Adobe PDF, which is not supported.", comment: "")
                updatedFailureError = NSError(
                    domain: TPPErrorLogger.clientDomain,
                    code: TPPErrorCode.ignore.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: msg]
                )
                delegate?.logBookDownloadFailure(book, reason: "Received PDF for AdobeDRM rights", downloadTask: task, metadata: nil)
                failureRequiringAlert = true
            } else if let acsmData = try? Data(contentsOf: location) {
                // deferred Adobe device activation from login to borrow
                // time, but the download-retry path bypasses borrow — so we
                // must also guarantee activation here before fulfillment.
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.adobeDRMService.ensureDeviceActivated()
                        // Read the Sendable credential values off the (shared,
                        // non-Sendable) TPPUserAccount up front so the MainActor
                        // hop captures only `String?`s, not the account object.
                        let ua = self.userAccountProvider()
                        let userID = ua.userID
                        let deviceID = ua.deviceID
                        Log.info(#file, "Adobe DRM activated — fulfilling ACSM for '\(book.title)' with userID: \(userID ?? "nil")")
                        await MainActor.run {
                            self.adobeDRMService.fulfill(withACSMData: acsmData, tag: book.identifier, userID: userID, deviceID: deviceID)
                        }
                    } catch {
                        Log.error(#file, "Adobe DRM activation failed for '\(book.title)': \(error.localizedDescription)")
                        await MainActor.run {
                            self.bookRegistry.setState(.downloadFailed, for: book.identifier)
                            self.delegate?.alertForProblemDocument(nil, error: error, book: book)
                        }
                    }
                }
            }
            #endif

        case .lcp:
            delegate?.fulfillLCPLicense(fileUrl: location, forBook: book, downloadTask: task)

        case .simplifiedBearerTokenJSON:
            if let data = try? Data(contentsOf: location) {
                if let dictionary = TPPJSONObjectFromData(data) as? [String: Any],
                   let simplifiedBearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dictionary) {
                    let cmFulfillURL = task.originalRequest?.url
                    simplifiedBearerToken.fulfillURL = cmFulfillURL

                    var mutableRequest = URLRequest(url: simplifiedBearerToken.location, applyingCustomUserAgent: true)
                    mutableRequest.setValue("Bearer \(simplifiedBearerToken.accessToken)", forHTTPHeaderField: "Authorization")
                    let newTask = session.downloadTask(with: mutableRequest as URLRequest)
                    let downloadInfo = MyBooksDownloadInfo(
                        downloadProgress: 0.0,
                        downloadTask: newTask,
                        rightsManagement: .none,
                        bearerToken: simplifiedBearerToken
                    )
                    await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
                    book.bearerToken = simplifiedBearerToken.accessToken
                    book.bearerTokenFulfillURL = cmFulfillURL
                    await stateManager.taskIdentifierToBook.set(newTask.taskIdentifier, value: book)

                    // PP-5023: durably record the task this hop starts. The
                    // bearer location is a DIFFERENT URL from the one the record
                    // was written with at download start, so without this the
                    // record names a URL nothing is fetching while a live task
                    // runs unrecorded — invisible to reconciliation's
                    // contested-URL guard, and adoptable by any book whose record
                    // happens to name the bearer location.
                    stateManager.persistReissuedTask(
                        bookID: book.identifier,
                        taskIdentifier: newTask.taskIdentifier,
                        downloadURL: simplifiedBearerToken.location)

                    newTask.resume()
                    followUpTaskInFlight = true
                } else {
                    delegate?.logBookDownloadFailure(book, reason: "No Simplified Bearer Token in deserialized data", downloadTask: task, metadata: nil)
                    delegate?.failDownloadWithAlert(for: book, withMessage: nil)
                }
            } else {
                delegate?.logBookDownloadFailure(book, reason: "No Simplified Bearer Token data available on disk", downloadTask: task, metadata: nil)
                delegate?.failDownloadWithAlert(for: book, withMessage: nil)
            }

        case .overdriveManifestJSON:
            failureRequiringAlert = !fileOps.replaceBook(book, withFileAtURL: location, forDownloadTask: task)

        case .none:
            failureRequiringAlert = !fileOps.moveFile(at: location, toDestinationForBook: book, forDownloadTask: task)
        }

        return RightsManagementDispatchResult(
            failureRequiringAlert: failureRequiringAlert,
            failureError: updatedFailureError,
            followUpTaskInFlight: followUpTaskInFlight
        )
    }
}
