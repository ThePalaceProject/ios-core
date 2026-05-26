//
//  DownloadCompletionParser.swift
//  Palace
//
//  Owns the pre-dispatch parsing block of the URL session
//  download-completion path that lived inside MyBooksDownloadCenter
//  as the head of `handleDownloadCompletion(session:task:location:)`.
//  Resolves the book's rights (with cache write-back), detects RFC
//  7807 problem documents, routes OPDS entry / OPDS2 publication
//  responses through the BackgroundDownloadHandler, and gates the
//  remaining payload on `book.canCompleteDownload(withContentType:)`.
//
//  Returns a single `DownloadCompletionParseResult` describing what
//  the consumer should do next: bail out (a follow-up download was
//  started), surface a failure (with optional parsed problem doc),
//  or proceed to the per-rights-management dispatch step.
//

import Foundation
import PalaceCatalog
import PalaceLogging

// MARK: - Routing surface

/// Subset of `BackgroundDownloadHandler` the parser reaches for.
/// A protocol so tests can stub the OPDS-routing async methods
/// without standing up the full URLSession + delegate graph.
protocol DownloadCompletionRouting: AnyObject {
    func detectRightsManagement(from mimeType: String) -> MyBooksDownloadInfo.MyBooksDownloadRightsManagement
    func isOPDSEntryMimeType(_ mimeType: String) -> Bool
    func isOPDS2PublicationMimeType(_ mimeType: String) -> Bool
    func handleOPDSEntryResponse(
        at location: URL,
        for book: TPPBook,
        originalTask: URLSessionDownloadTask,
        session: URLSession
    ) async -> Bool
    func handleOPDS2PublicationResponse(
        at location: URL,
        for book: TPPBook,
        originalTask: URLSessionDownloadTask,
        session: URLSession
    ) async -> Bool
}

extension BackgroundDownloadHandler: DownloadCompletionRouting {}

// MARK: - Result

enum DownloadCompletionParseResult {
    /// The OPDS routing already kicked off a follow-up download for
    /// the actual content. Caller should return early and skip both
    /// the per-rights dispatch and the failure-alert tail.
    case followUpStarted

    /// Parsing surfaced a failure (problem doc, OPDS-routing failure,
    /// or unsupported content type). Caller skips per-rights dispatch
    /// and routes through the auth-retry / alert tail with the carried
    /// problem doc + mimeType + already-resolved rights.
    case failure(
        problemDoc: TPPProblemDocument?,
        mimeType: String,
        rights: MyBooksDownloadInfo.MyBooksDownloadRightsManagement
    )

    /// Payload looks routable. Caller proceeds to the per-rights
    /// dispatch switch with the resolved rights + mimeType.
    case proceed(
        rights: MyBooksDownloadInfo.MyBooksDownloadRightsManagement,
        mimeType: String
    )
}

// MARK: - DownloadCompletionParser

final class DownloadCompletionParser {

    private let routing: DownloadCompletionRouting
    private let stateManager: DownloadStateManager

    init(routing: DownloadCompletionRouting, stateManager: DownloadStateManager) {
        self.routing = routing
        self.stateManager = stateManager
    }

    func parse(
        book: TPPBook,
        task: URLSessionDownloadTask,
        location: URL,
        session: URLSession
    ) async -> DownloadCompletionParseResult {
        let mimeType = task.response?.mimeType ?? ""

        var rights = await stateManager.bookIdentifierToDownloadInfo
            .get(book.identifier)?.rightsManagement ?? .unknown

        if rights == .unknown, let detectedFrom = task.response?.mimeType {
            Log.info(#file, "⚠️ Rights unknown, detecting from completion MIME type: \(detectedFrom)")
            rights = routing.detectRightsManagement(from: detectedFrom)
            if let info = await stateManager.bookIdentifierToDownloadInfo
                .get(book.identifier)?.withRightsManagement(rights) {
                await stateManager.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
            }
        }

        Log.info(#file, "Download completed for \(book.identifier) with rights: \(rights)")

        if let response = task.response, response.isProblemDocument() {
            let problemDocData = (try? Data(contentsOf: location)) ?? Data()
            let problemDoc = TPPProblemDocument.fromProblemResponseData(problemDocData)
            if problemDoc == nil {
                TPPErrorLogger.logProblemDocumentParseError(
                    NSError(
                        domain: "MyBooksDownloadCenter",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not parse problem document"]
                    ),
                    problemDocumentData: problemDocData.isEmpty ? nil : problemDocData,
                    url: location,
                    summary: "Error parsing problem doc downloading \(String(describing: book.distributor)) book",
                    metadata: ["book": book.loggableShortString]
                )
            }
            try? FileManager.default.removeItem(at: location)
            return .failure(problemDoc: problemDoc, mimeType: mimeType, rights: rights)
        }

        if routing.isOPDSEntryMimeType(mimeType) {
            Log.info(#file, "📖 Received OPDS entry response for \(book.identifier), attempting to extract acquisition link")
            if await routing.handleOPDSEntryResponse(at: location, for: book, originalTask: task, session: session) {
                try? FileManager.default.removeItem(at: location)
                return .followUpStarted
            }
            Log.warn(#file, "⚠️ Failed to extract acquisition link from OPDS entry for \(book.identifier)")
            try? FileManager.default.removeItem(at: location)
            return .failure(problemDoc: nil, mimeType: mimeType, rights: rights)
        }

        if routing.isOPDS2PublicationMimeType(mimeType) {
            Log.info(#file, "📖 Received OPDS2 publication JSON for \(book.identifier), extracting fulfillment link")
            if await routing.handleOPDS2PublicationResponse(at: location, for: book, originalTask: task, session: session) {
                try? FileManager.default.removeItem(at: location)
                return .followUpStarted
            }
            Log.warn(#file, "⚠️ Failed to extract fulfillment link from OPDS2 publication for \(book.identifier)")
            try? FileManager.default.removeItem(at: location)
            return .failure(problemDoc: nil, mimeType: mimeType, rights: rights)
        }

        if !book.canCompleteDownload(withContentType: mimeType) {
            try? FileManager.default.removeItem(at: location)
            return .failure(problemDoc: nil, mimeType: mimeType, rights: rights)
        }

        return .proceed(rights: rights, mimeType: mimeType)
    }
}
