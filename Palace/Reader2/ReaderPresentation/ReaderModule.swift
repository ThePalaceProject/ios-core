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
import ReadiumShared


/// Base module delegate, that sub-modules' delegate can extend.
/// Provides basic shared functionalities.
protocol ModuleDelegate: AnyObject {
  func presentAlert(_ title: String, message: String, from viewController: UIViewController)
  func presentError(_ error: Error?, from viewController: UIViewController)
}

// MARK:-

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

// MARK:-

/// The ReaderModule handles the presentation of a publication.
///
/// It contains sub-modules implementing `ReaderFormatModule` to handle each
/// publication format (e.g. EPUB, PDF, etc).
final class ReaderModule: ReaderModuleAPI {

  weak var delegate: ModuleDelegate?
  private let bookRegistry: TPPBookRegistryProvider
  private let progressSynchronizer: TPPLastReadPositionSynchronizer

  /// Sub-modules to handle different publication formats (eg. EPUB, CBZ)
  var formatModules: [ReaderFormatModule] = []

  init(delegate: ModuleDelegate?,
       resourcesServer: HTTPServer,
       bookRegistry: TPPBookRegistryProvider) {
    self.delegate = delegate
    self.bookRegistry = bookRegistry
    self.progressSynchronizer = TPPLastReadPositionSynchronizer(bookRegistry: bookRegistry)

    formatModules = [
      EPUBModule(delegate: self.delegate, resourcesServer: resourcesServer)
    ]
  }

  func presentPublication(_ publication: Publication,
                          book: TPPBook,
                          in navigationController: UINavigationController,
                          forSample: Bool = false) {
    if delegate == nil {
      TPPErrorLogger.logError(nil, summary: "ReaderModule delegate is not set")
    }

    guard let formatModule = self.formatModules.first(where:{ $0.supports(publication) }) else {
      delegate?.presentError(ReaderError.formatNotSupported, from: navigationController)
      return
    }

    // TODO: SIMPLY-2656 remove implicit dependency (TPPUserAccount.shared)
    let drmDeviceID = TPPUserAccount.sharedAccount().deviceID
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
    Task {
      do {
        let lastSavedLocation = bookRegistry.location(forIdentifier: book.identifier)
        let initialLocator = await lastSavedLocation?.convertToLocator()
        var normalizedLocator: Locator?
        if let jsonString = initialLocator?.jsonString {
          normalizedLocator = try Locator(legacyJSONString: jsonString)
        }


        let readerVC = try await formatModule.makeReaderViewController(
          for: publication,
          book: book,
          initialLocation: normalizedLocator,
          forSample: forSample
        )

        DispatchQueue.main.async {
        // Ensure all UI updates are performed on the main thread
          let backItem = UIBarButtonItem()
          backItem.title = Strings.Generic.back
          readerVC.navigationItem.backBarButtonItem = backItem
          readerVC.extendedLayoutIncludesOpaqueBars = true
          readerVC.hidesBottomBarWhenPushed = true
          navigationController.pushViewController(readerVC, animated: true)
        }

      } catch {
        DispatchQueue.main.async { [weak self] in
          self?.delegate?.presentError(error, from: navigationController)
        }
      }
    }
  }
}
