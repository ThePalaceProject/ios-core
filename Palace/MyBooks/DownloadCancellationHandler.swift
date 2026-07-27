//
//  DownloadCancellationHandler.swift
//  Palace
//
//  Owns `cancelDownload(for:)` — the cancellation state machine that
//  lived inside MyBooksDownloadCenter. Two paths:
//
//    1. **No download task** (e.g. the user cancelled during a borrow
//       request, while waiting for a retry, or before the URL session
//       task was created). Allowed only for cancellable states
//       (.downloading / .downloadFailed / .SAMLStarted); other states
//       are nonsensical cancels and ignored. The handler resets the
//       book to .downloadNeeded, broadcasts an update, and frees the
//       download-coordinator slot.
//
//    2. **Download task present**. Adobe DRM short-circuits to
//       adobeDRMService.cancelFulfillment (Adobe owns its own
//       lifecycle via NYPLADEPTDelegate callbacks). For all other
//       rights, the handler sets state to .downloadNeeded + broadcasts
//       BEFORE calling URLSessionDownloadTask.cancel — UI updates
//       immediately rather than waiting for the URLSession callback —
//       and the cancel completion clears both bookIdentifierToDownloadInfo
//       and taskIdentifierToBook so a subsequent retry isn't blocked
//       by stale entries.
//

import Foundation
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - Delegate

protocol DownloadCancellationHandlerDelegate: AnyObject {
    func broadcastUpdate()
    func schedulePendingStartsIfPossible()
}

// MARK: - DownloadCancellationHandler

/// - Sendable invariant (Swift 6 `complete`-mode): the stored dependencies
///   (`stateManager`, `bookRegistry`, `adobeDRMService`) are all `let` bound at
///   init; the only mutable member is `weak var delegate`, assigned exactly once
///   during owner (`MyBooksDownloadCenter`) construction and never reassigned
///   (weak-ref reads + ARC zeroing are atomic). The cancel paths hop teardown
///   into `Task { }` / the URLSession `cancel` completion, touching only the
///   actor-serialized `stateManager.downloadCoordinator` / `SafeDictionary`
///   members and the main-thread `delegate` callbacks. `@unchecked` only
///   because the stored service types are not themselves `Sendable`.
final class DownloadCancellationHandler: @unchecked Sendable {

    /// Bookkeeping states that signify a download or borrow is in flight
    /// without a URL session task — cancellation must clean these up.
    private static let cancellableNoTaskStates: [TPPBookState] = [
        .downloading, .downloadFailed, .SAMLStarted
    ]

    weak var delegate: DownloadCancellationHandlerDelegate?

    /// Handle to the most recently spawned cancel-teardown `Task`. The cancel
    /// paths do their coordinator/map teardown inside a fire-and-forget
    /// `Task { }` (spawned either from the no-task branch or from the
    /// URLSession `cancel` completion). Retaining the handle lets callers —
    /// and tests — `await lastCancelTeardownTask?.value` to join that teardown
    /// deterministically instead of polling for the resulting state. Behavior
    /// is unchanged: the same Task is created and runs exactly as before; only
    /// a reference to it is now kept.
    private(set) var lastCancelTeardownTask: Task<Void, Never>?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider
    #if FEATURE_DRM_CONNECTOR
    private let adobeDRMService: AdobeDRMService
    #endif

    #if FEATURE_DRM_CONNECTOR
    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        adobeDRMService: AdobeDRMService
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
        self.adobeDRMService = adobeDRMService
    }
    #else
    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
    }
    #endif

    // MARK: - Cancel

    func cancelDownload(for identifier: String) {
        let state = bookRegistry.state(for: identifier)

        guard let info = stateManager.bookIdentifierToDownloadInfo.syncGet(identifier) else {
            // No URL session task — only allow cancellation for states
            // that signify a download or borrow is genuinely in flight.
            if Self.cancellableNoTaskStates.contains(state) {
                Log.info(#file, "📊 Cancelling download without task for '\(identifier)' (state: \(state.stringValue()))")
                bookRegistry.setState(.downloadNeeded, for: identifier)
                delegate?.broadcastUpdate()

                lastCancelTeardownTask = Task { [weak self] in
                    guard let self else { return }
                    await self.stateManager.downloadCoordinator.removeCachedDownloadInfo(for: identifier)
                    await self.stateManager.downloadCoordinator.registerCompletion(identifier: identifier)
                    let remainingCount = await self.stateManager.downloadCoordinator.activeCount
                    Log.info(#file, "📊 Download cancelled (no task) for '\(identifier)', remaining active: \(remainingCount)")
                    self.delegate?.schedulePendingStartsIfPossible()
                }
                return
            }

            NSLog("Ignoring nonsensical cancellation request for state: \(state.stringValue())")
            return
        }

        #if FEATURE_DRM_CONNECTOR
        if info.rightsManagement == .adobe {
            // Adobe DRM owns its own lifecycle through NYPLADEPTDelegate;
            // routing the URL session cancel through it would race with the
            // Adobe state machine. Short-circuit here.
            adobeDRMService.cancelFulfillment(withTag: identifier)
            return
        }
        #endif

        let taskId = info.downloadTask.taskIdentifier

        // Update UI BEFORE cancelling so the user sees feedback immediately.
        bookRegistry.setState(.downloadNeeded, for: identifier)
        delegate?.broadcastUpdate()

        info.downloadTask.cancel { [weak self] _ in
            guard let self else { return }

            self.lastCancelTeardownTask = Task { [weak self] in
                guard let self else { return }
                // Clear both maps so retry isn't blocked by stale entries.
                _ = await self.stateManager.bookIdentifierToDownloadInfo.remove(identifier)
                _ = await self.stateManager.taskIdentifierToBook.remove(taskId)
                await self.stateManager.downloadCoordinator.removeCachedDownloadInfo(for: identifier)
                await self.stateManager.downloadCoordinator.registerCompletion(identifier: identifier)
                let remainingCount = await self.stateManager.downloadCoordinator.activeCount
                Log.info(#file, "📊 Download cancelled for '\(identifier)', remaining active: \(remainingCount)")
                self.delegate?.schedulePendingStartsIfPossible()
            }
        }
    }
}
