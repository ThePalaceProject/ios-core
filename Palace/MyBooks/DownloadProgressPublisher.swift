//
//  DownloadProgressPublisher.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter to provide single-responsibility
//  Combine-based progress and error reporting for downloads.
//

import Foundation
import Combine
import UIKit

// MARK: - DownloadProgressPublishing Protocol

protocol DownloadProgressPublishing: AnyObject {
    /// Publishes (bookIdentifier, progress) tuples for download progress updates
    var downloadProgressPublisher: PassthroughSubject<(String, Double), Never> { get }

    /// Publishes download/borrow error info for inline alert presentation
    var downloadErrorPublisher: PassthroughSubject<DownloadErrorInfo, Never> { get }

    /// Sends a progress update for a book
    func sendProgress(bookIdentifier: String, progress: Double)

    /// Publishes an error and announces it via VoiceOver
    func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo)

    /// Broadcasts a general update notification (throttled)
    func broadcastUpdate()
}

// MARK: - DownloadProgressReporter

/// Handles Combine-based progress reporting, error publishing, and
/// throttled broadcast notifications for download state changes.
final class DownloadProgressReporter: DownloadProgressPublishing {

    // MARK: - Publishers

    let downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
    let downloadErrorPublisher = PassthroughSubject<DownloadErrorInfo, Never>()

    // MARK: - Dependencies

    private let accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter

    // MARK: - Broadcast throttling

    @MainActor private var lastBroadcastTime: Date = Date.distantPast
    @MainActor private var pendingBroadcast: DispatchWorkItem?

    /// The object to use as the notification sender (typically MyBooksDownloadCenter.shared)
    weak var notificationSender: AnyObject?

    // MARK: - Init

    init(accessibilityAnnouncements: TPPAccessibilityAnnouncementCenter = TPPAccessibilityAnnouncementCenter()) {
        self.accessibilityAnnouncements = accessibilityAnnouncements
    }

    // MARK: - Progress

    func sendProgress(bookIdentifier: String, progress: Double) {
        Task { @MainActor in
            downloadProgressPublisher.send((bookIdentifier, progress))
        }
    }

    // MARK: - Error Publishing

    /// Publishes an error to `downloadErrorPublisher` and simultaneously announces
    /// it via VoiceOver so assistive technology users hear the error without
    /// needing to navigate to the alert element.
    func publishAndAnnounceError(_ errorInfo: DownloadErrorInfo) {
        downloadErrorPublisher.send(errorInfo)
        accessibilityAnnouncements.announceStatus(title: errorInfo.title, message: errorInfo.message)
    }

    // MARK: - Broadcast

    func broadcastUpdate() {
        Task { @MainActor [weak self] in
            self?.broadcastUpdateOnMain()
        }
    }

    @MainActor private func broadcastUpdateOnMain() {
        pendingBroadcast?.cancel()

        let timeSinceLastBroadcast = Date().timeIntervalSince(lastBroadcastTime)
        let minimumBroadcastInterval: TimeInterval = 0.5

        if timeSinceLastBroadcast >= minimumBroadcastInterval {
            broadcastUpdateNow()
        } else {
            let delay = minimumBroadcastInterval - timeSinceLastBroadcast
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.broadcastUpdateNow()
                }
            }
            pendingBroadcast = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    @MainActor private func broadcastUpdateNow() {
        lastBroadcastTime = Date()
        pendingBroadcast = nil

        NotificationCenter.default.post(
            name: Notification.Name.TPPMyBooksDownloadCenterDidChange,
            object: notificationSender
        )
    }

    // MARK: - Accessibility Announcements

    func announceDownloadStarted(for book: TPPBook) {
        accessibilityAnnouncements.announceDownloadStarted(title: book.title)
    }

    func announceDownloadProgress(for book: TPPBook, progress: Double) {
        accessibilityAnnouncements.announceDownloadProgress(
            title: book.title,
            identifier: book.identifier,
            progress: progress
        )
    }

    func announceDownloadCompleted(for book: TPPBook) {
        accessibilityAnnouncements.announceDownloadCompleted(title: book.title)
        accessibilityAnnouncements.resetProgress(identifier: book.identifier)
    }

    func announceDownloadFailed(for book: TPPBook) {
        accessibilityAnnouncements.announceDownloadFailed(title: book.title)
        accessibilityAnnouncements.resetProgress(identifier: book.identifier)
    }

    func announceBorrowStarted(for book: TPPBook) {
        accessibilityAnnouncements.announceBorrowStarted(title: book.title)
    }

    func announceBorrowSucceeded(for book: TPPBook) {
        accessibilityAnnouncements.announceBorrowSucceeded(title: book.title)
    }

    func announceBorrowFailed(for book: TPPBook) {
        accessibilityAnnouncements.announceBorrowFailed(title: book.title)
    }

    func announceReturnStarted(for book: TPPBook) {
        accessibilityAnnouncements.announceReturnStarted(title: book.title)
    }

    func announceReturnSucceeded(for book: TPPBook) {
        accessibilityAnnouncements.announceReturnSucceeded(title: book.title)
    }

    func announceReturnFailed(for book: TPPBook) {
        accessibilityAnnouncements.announceReturnFailed(title: book.title)
    }
}
