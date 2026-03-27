//
//  MyBooksDownloadCenterProtocol.swift
//  Palace
//
//  Created for dependency injection support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Protocol for the download center, enabling dependency injection for testing.
///
/// This protocol extracts the consumer-facing interface from `MyBooksDownloadCenter`,
/// allowing tests to inject mock implementations instead of relying on the singleton.
protocol MyBooksDownloadCenterProviding: AnyObject {

    // MARK: - Publishers

    /// Publishes download progress updates as (bookIdentifier, progress) tuples.
    var downloadProgressPublisher: PassthroughSubject<(String, Double), Never> { get }

    /// Publishes download error alerts for a given book identifier.
    var downloadErrorPublisher: PassthroughSubject<DownloadErrorInfo, Never> { get }

    // MARK: - Borrowing

    /// Initiates a borrow for the given book, optionally starting a download on success.
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)

    // MARK: - Downloading

    /// Starts downloading content for the given book.
    func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?)

    /// Cancels an in-progress download for the book with the given identifier.
    func cancelDownload(for identifier: String)

    // MARK: - Content Management

    /// Deletes local content for the book with the given identifier.
    func deleteLocalContent(for identifier: String, account: String?)

    /// Returns the book with the given identifier to the library.
    func returnBook(withIdentifier identifier: String, completion: (() -> Void)?)

    // MARK: - Download Info

    /// Returns download info for the book with the given identifier (synchronous).
    func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo?

    /// Returns download info for the book with the given identifier (async).
    func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo?

    // MARK: - File Management

    /// Returns the local file URL for the book with the given identifier.
    func fileUrl(for identifier: String) -> URL?

    /// Returns the local file URL for the book with the given identifier and account.
    func fileUrl(for identifier: String, account: String?) -> URL?

    // MARK: - State

    /// Broadcasts a download state update notification.
    func broadcastUpdate()

    /// Resets the download center, clearing all state.
    func reset()
}

// MARK: - MyBooksDownloadCenter Conformance

extension MyBooksDownloadCenter: MyBooksDownloadCenterProviding {}
