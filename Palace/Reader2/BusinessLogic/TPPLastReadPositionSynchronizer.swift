//
//  TPPLastReadPositionSynchronizer.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 3/9/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging
import PalaceReadingPosition
@preconcurrency import ReadiumShared

/// A front-end to the position-load path that resolves cross-device read
/// position conflicts. The remote fetch is delegated to a `PositionWriter`;
/// the conflict-resolution rule (same-device-no-precedence, equal-location
/// no-op) stays in this class because it's EPUB-specific and not part of
/// the writer's contract.
///
/// - Note: `@unchecked Sendable` is safe here: the class holds only immutable
///   (`let`) references and adds no mutable state of its own. `bookRegistry` and
///   `positionWriter` are thread-safe service objects. This lets `self` be
///   captured by the main-thread alert/continuation `@Sendable` closures in
///   `presentNavigationAlert` without crossing a Sendable boundary.
final class TPPLastReadPositionSynchronizer: @unchecked Sendable {
    typealias DisplayStrings = Strings.TPPLastReadPositionSynchronizer

    private let bookRegistry: TPPBookRegistryProvider
    private let positionWriter: PositionWriter?

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - bookRegistry: The registry that stores the reading progresses.
    ///   - positionWriter: The writer used to load the server-side position.
    ///     When `nil` (the default), a fresh `EPUBPositionAdapter`-backed
    ///     writer is constructed per-call against the syncing book.
    init(bookRegistry: TPPBookRegistryProvider,
         positionWriter: PositionWriter? = nil) {
        self.bookRegistry = bookRegistry
        self.positionWriter = positionWriter
    }

    /// Fetches the read position from the server and alerts the user
    /// if it differs from the local position or if it comes from a
    /// different device.
    ///
    /// Before the `completion` closure is called, the `bookRegistry` is going
    /// to be updated with the correct progress location, if needed.
    ///
    /// - Parameters:
    ///   - publication: The R2 publication associated with the current `book`.
    ///   - book: The book whose position needs syncing.
    ///   - drmDeviceID: The device ID is used to identify if the last read
    ///   position retrieved from the server was from a different device.
    ///   - completion: Called when syncing is complete.
    func sync(for publication: Publication,
              book: TPPBook,
              drmDeviceID: String?,
              completion: @escaping () -> Void) {
        // Swift 6 `complete`: box the non-Sendable `() -> Void` completion so the
        // `@Sendable` `Task` captures a Sendable carrier. We box rather than mark
        // the param `@Sendable` because the `ReaderModule` caller closure
        // captures non-Sendable main-actor values (`formatModule`,
        // `navigationController`); `@Sendable` would ripple onto that call site.
        // INVARIANT — the boxed closure runs only on the main thread (via
        // `TPPMainThreadRun.asyncIfNeeded`).
        let completionBox = VoidCompletionBox(completion)
        Task {
            await sync(for: publication, book: book, drmDeviceID: drmDeviceID)
            TPPMainThreadRun.asyncIfNeeded {
                completionBox.call()
            }
        }
    }

    func sync(for publication: Publication,
              book: TPPBook,
              drmDeviceID: String?) async {
        let serverLocator = await syncReadPosition(for: book, drmDeviceID: drmDeviceID, publication: publication)

        if let serverLocator = serverLocator {
            await presentNavigationAlert(for: serverLocator,
                                         publication: publication,
                                         book: book)
        }
    }

    // MARK: - Private methods

    private func syncReadPosition(for book: TPPBook, drmDeviceID: String?, publication: Publication) async -> Locator? {
        let localLocation = bookRegistry.location(forIdentifier: book.identifier)
        let writer = positionWriter ?? EPUBPositionWriterFactory.make(for: book)

        let remote: PositionSnapshot?
        do {
            remote = try await writer.load(for: book.identifier)
        } catch {
            Log.info(#function, "Failed to load remote reading position for \(book.loggableShortString()): \(error)")
            return nil
        }

        guard let snapshot = remote else {
            Log.info(#function, "No reading position annotation exists on the server for \(book.loggableShortString()).")
            return nil
        }

        let deviceID = snapshot.device
        let serverLocationString = String(data: snapshot.payload, encoding: .utf8) ?? ""

        // Pass through returning nil (meaning the server doesn't have a
        // last read location worth restoring) if:
        // 1 - The most recent page on the server comes from the same device and there is no localLocation, or
        // 2 - The server and the client have the same page marked
        if (deviceID == drmDeviceID && localLocation != nil)
            || localLocation?.locationString == serverLocationString {

            // Server location does not differ from or should take no precedence
            // over the local position.
            return nil
        }

        // We got a server location that differs from the local: return that
        // so that clients can decide what to do.
        let bookLocation = TPPBookLocation(locationString: serverLocationString,
                                           renderer: TPPBookLocation.r3Renderer)
        return await bookLocation?.convertToLocator(publication: publication)
    }

    private func presentNavigationAlert(for serverLocator: Locator,
                                        publication: Publication,
                                        book: TPPBook,
                                        completion: @escaping () -> Void) {
        // Swift 6 `complete`: box the non-Sendable `() -> Void` completion for the
        // `@Sendable` `Task` capture, matching `sync(for:book:drmDeviceID:completion:)`.
        let completionBox = VoidCompletionBox(completion)
        Task {
            await presentNavigationAlert(for: serverLocator, publication: publication, book: book)
            completionBox.call()
        }
    }

    /// Async version of `presentNavigationAlert`.
    private func presentNavigationAlert(for serverLocator: Locator,
                                        publication: Publication,
                                        book: TPPBook) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard let window = UIApplication.shared.delegate?.window as? UIWindow,
                      let rootVC = window.rootViewController else {
                    continuation.resume()
                    return
                }

                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }

                guard topVC.view.window != nil else {
                    continuation.resume()
                    return
                }

                let alert = UIAlertController(title: DisplayStrings.syncReadingPositionAlertTitle,
                                              message: DisplayStrings.syncReadingPositionAlertBody,
                                              preferredStyle: .alert)

                let stayText = DisplayStrings.stay
                let stayAction = UIAlertAction(title: stayText, style: .cancel) { _ in
                    continuation.resume()
                }

                let moveText = DisplayStrings.move
                let moveAction = UIAlertAction(title: moveText, style: .default) { _ in
                    let loc = TPPBookLocation(locator: serverLocator,
                                              type: "LocatorHrefProgression",
                                              publication: publication)
                    self.bookRegistry.setLocation(loc, forIdentifier: book.identifier)
                    continuation.resume()
                }

                alert.addAction(stayAction)
                alert.addAction(moveAction)

                // Present *after* any in-flight transition settles. This prompt
                // fires during launch/book-open, exactly when a push/modal
                // transition can still be animating; presenting into it is the
                // fe741015 CA-commit race. Wait on the transition coordinator
                // (re-walking to the settled topmost) instead of presenting raw.
                // The continuation is resumed only by the alert's actions, so the
                // alert must always be presented — never dropped.
                if let coordinator = topVC.transitionCoordinator {
                    coordinator.animate(alongsideTransition: nil) { _ in
                        DispatchQueue.main.async {
                            var settledTop = rootVC
                            while let presented = settledTop.presentedViewController {
                                settledTop = presented
                            }
                            settledTop.present(alert, animated: true)
                        }
                    }
                } else {
                    topVC.present(alert, animated: true)
                }
            }
        }
    }
}

/// Sendable carrier for a non-Sendable `() -> Void` completion closure captured
/// by the `@Sendable` `Task`s in `TPPLastReadPositionSynchronizer`. Boxing
/// avoids rippling `@Sendable` onto the `sync(...completion:)` signature, whose
/// `ReaderModule` caller closure captures non-Sendable main-actor values.
/// INVARIANT — the boxed closure runs only on the main thread (via
/// `TPPMainThreadRun.asyncIfNeeded` / the alert-action continuation).
private final class VoidCompletionBox: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
