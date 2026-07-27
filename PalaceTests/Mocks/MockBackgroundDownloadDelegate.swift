//
//  MockBackgroundDownloadDelegate.swift
//  PalaceTests
//
//  Shared mock for BackgroundDownloadHandlerDelegate.
//  Extracted from BackgroundDownloadHandlerTests for reuse across test files.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceCatalog
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

final class MockBackgroundDownloadDelegate: BackgroundDownloadHandlerDelegate {
    let stateManager = DownloadStateManager()
    let progressReporter: DownloadProgressReporter
    let bookRegistry: TPPBookRegistryProvider
    let userAccount: TPPUserAccount
    let tokenInterceptor: TokenRefreshInterceptor

    var handleDownloadCompletionCalls: [(session: URLSession, task: URLSessionDownloadTask, location: URL)] = []
    var handleTaskCompletionErrorCalls: [(task: URLSessionTask, error: Error?)] = []
    var schedulePendingStartsCalled = false
    var failDownloadCalls: [(book: TPPBook, message: String?)] = []
    var alertForProblemCalls: [(problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook)] = []
    var logBookDownloadFailureCalls: [(book: TPPBook, reason: String)] = []
    var fulfillLCPCalls: [(fileUrl: URL, book: TPPBook)] = []
    var fileUrls: [String: URL] = [:]

    init(
        bookRegistry: TPPBookRegistryProvider = TPPBookRegistryMock(),
        userAccount: TPPUserAccount = TPPUserAccountMock()
    ) {
        self.bookRegistry = bookRegistry
        self.userAccount = userAccount
        self.tokenInterceptor = TokenRefreshInterceptor()
        self.progressReporter = DownloadProgressReporter(
            accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter(
                postHandler: { _, _ in },
                isVoiceOverRunning: { false }
            )
        )
    }

    func handleDownloadCompletion(session: URLSession, task: URLSessionDownloadTask, location: URL) async {
        handleDownloadCompletionCalls.append((session: session, task: task, location: location))
    }

    func handleTaskCompletionError(task: URLSessionTask, error: Error?) async {
        handleTaskCompletionErrorCalls.append((task: task, error: error))
    }

    func schedulePendingStartsIfPossible() {
        schedulePendingStartsCalled = true
    }

    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?) {
        failDownloadCalls.append((book: book, message: message))
    }

    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
        alertForProblemCalls.append((problemDoc: problemDoc, error: error, book: book))
    }

    func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) {
        logBookDownloadFailureCalls.append((book: book, reason: reason))
    }

    func fileUrl(for identifier: String) -> URL? {
        return fileUrls[identifier]
    }

    func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask) {
        fulfillLCPCalls.append((fileUrl: fileUrl, book: book))
    }
}
