//
//  ReaderModule.swift
//  The Palace Project
//
//  Created by Mickaël Menu on 22.02.19.
//
//  Copyright 2019 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import Foundation
import UIKit
// Swift 6 `complete`: `Publication` (and `Locator`, produced by
// `convertToLocator`) are non-Sendable Readium types that this module hands to
// `formatModule.makeReaderViewController(...)` from inside a `Task.detached` and
// across `MainActor.run`. `@preconcurrency` is the honest ceiling until Readium
// annotates these types Sendable; the module's own concurrency contract is
// documented on the `@unchecked Sendable` conformance below.
@preconcurrency import ReadiumShared
import PalaceBookModel

/// Base module delegate, that sub-modules' delegate can extend.
/// Provides basic shared functionalities.
protocol ModuleDelegate: AnyObject {
    func presentAlert(_ title: String, message: String, from viewController: UIViewController)
    func presentError(_ error: Error?, from viewController: UIViewController)
}

// MARK: -

/// The ReaderModuleAPI declares what is needed to handle the presentation
/// of a publication.
protocol ReaderModuleAPI {

    var delegate: ModuleDelegate? { get }

    /// Presents the given publication to the user, inside the given navigation controller.
    /// - Parameter publication: The R2 publication to display.
    /// - Parameter book: Our internal book model related to the `publication`.
    /// - Parameter navigationController: The navigation stack the book will be presented in.
    /// - Parameter completion: Called once the publication is presented, or if an error occured.
    func presentPublication(_ publication: Publication,
                            book: TPPBook,
                            in navigationController: UINavigationController,
                            forSample: Bool)
}

// MARK: -

/// The ReaderModule handles the presentation of a publication.
///
/// It contains sub-modules implementing `ReaderFormatModule` to handle each
/// publication format (e.g. EPUB, PDF, etc).
///
/// - Note: `@unchecked Sendable` is safe here. Stored state is effectively
///   immutable after `init`: `bookRegistry`, `progressSynchronizer`, and
///   `userAccount` are `let`; `delegate` and `formatModules` are assigned in
///   `init` and only read on the main thread during presentation. The single
///   `Task.detached` reads only the thread-safe `bookRegistry` (a `let`) off-main
///   and touches `delegate` exclusively inside `MainActor.run`. This lets `self`
///   be captured by the detached task's `@Sendable` `MainActor.run` closure
///   without crossing a Sendable boundary.
final class ReaderModule: ReaderModuleAPI, @unchecked Sendable {

    weak var delegate: ModuleDelegate?
    private let bookRegistry: TPPBookRegistryProvider
    private let progressSynchronizer: TPPLastReadPositionSynchronizer
    private let userAccount: TPPUserAccount

    /// Sub-modules to handle different publication formats (eg. EPUB, CBZ)
    var formatModules: [ReaderFormatModule] = []

    init(delegate: ModuleDelegate?,
         bookRegistry: TPPBookRegistryProvider,
         userAccount: TPPUserAccount = AppContainer.production().accountsManager.currentUserAccount) {
        self.delegate = delegate
        self.bookRegistry = bookRegistry
        self.userAccount = userAccount
        self.progressSynchronizer = TPPLastReadPositionSynchronizer(bookRegistry: bookRegistry)

        formatModules = [
            EPUBModule(delegate: self.delegate)
        ]
    }

    func presentPublication(_ publication: Publication,
                            book: TPPBook,
                            in navigationController: UINavigationController,
                            forSample: Bool = false) {
        if delegate == nil {
            TPPErrorLogger.logError(nil, summary: "ReaderModule delegate is not set")
        }

        guard let formatModule = self.formatModules.first(where: { $0.supports(publication) }) else {
            delegate?.presentError(ReaderError.formatNotSupported, from: navigationController)
            return
        }

        let drmDeviceID = userAccount.deviceID
        progressSynchronizer.sync(for: publication,
                                  book: book,
                                  drmDeviceID: drmDeviceID) { [weak self] in

            self?.finalizePresentation(for: publication,
                                       book: book,
                                       formatModule: formatModule,
                                       in: navigationController,
                                       forSample: forSample)
        }
    }

    func finalizePresentation(for publication: Publication,
                              book: TPPBook,
                              formatModule: ReaderFormatModule,
                              in navigationController: UINavigationController,
                              forSample: Bool = false) {
        // Swift 6 `complete`: the `Task.detached` closure is `@Sendable`, but
        // `formatModule` (a non-Sendable `ReaderFormatModule` existential) and
        // `navigationController` (a main-actor `UINavigationController`) are only
        // ever *used* on the main actor — `makeReaderViewController` is
        // `@MainActor`, and the nav controller is touched exclusively inside the
        // `MainActor.run` blocks. Box them so the detached task captures a
        // Sendable carrier rather than the raw main-actor values. INVARIANT: the
        // boxed values are dereferenced only on the main actor. Mirrors the
        // module's own `@unchecked Sendable` conformance rationale above.
        let presentationBox = ReaderPresentationBox(
            formatModule: formatModule,
            navigationController: navigationController
        )
        Task.detached { [weak self] in
            guard let self else { return }

            do {
                let lastSavedLocation = self.bookRegistry.location(forIdentifier: book.identifier)
                let initialLocator = await lastSavedLocation?.convertToLocator(publication: publication)

                let readerVC = try await presentationBox.formatModule.makeReaderViewController(
                    for: publication,
                    book: book,
                    initialLocation: initialLocator,
                    forSample: forSample
                )

                await MainActor.run {
                    let navigationController = presentationBox.navigationController
                    let backItem = UIBarButtonItem()
                    backItem.title = Strings.Generic.back
                    readerVC.navigationItem.backBarButtonItem = backItem
                    readerVC.extendedLayoutIncludesOpaqueBars = true
                    readerVC.navigationController?.isNavigationBarHidden = false
                    readerVC.hidesBottomBarWhenPushed = true
                    navigationController.pushViewController(readerVC, animated: true)
                }

            } catch {
                await MainActor.run {
                    self.delegate?.presentError(error, from: presentationBox.navigationController)
                }
            }
        }
    }
}

/// Sendable carrier for the main-actor-confined `formatModule` +
/// `navigationController` captured by the `@Sendable` `Task.detached` in
/// `ReaderModule.finalizePresentation`. INVARIANT — both stored values are only
/// dereferenced on the main actor: `makeReaderViewController` is `@MainActor`,
/// and `navigationController` is touched only inside `MainActor.run`.
private final class ReaderPresentationBox: @unchecked Sendable {
    let formatModule: ReaderFormatModule
    let navigationController: UINavigationController
    init(formatModule: ReaderFormatModule, navigationController: UINavigationController) {
        self.formatModule = formatModule
        self.navigationController = navigationController
    }
}
