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
import R2Shared


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
                          in navigationController: UINavigationController)
  
}

// MARK:-

/// The ReaderModule handles the presentation of a publication.
///
/// It contains sub-modules implementing `ReaderFormatModule` to handle each
/// publication format (e.g. EPUB, PDF, etc).
final class ReaderModule: ReaderModuleAPI {
  
  weak var delegate: ModuleDelegate?
  private let resourcesServer: ResourcesServer
  private let bookRegistry: TPPBookRegistryProvider
  private let progressSynchronizer: TPPLastReadPositionSynchronizer

  /// Sub-modules to handle different publication formats (eg. EPUB, CBZ)
  var formatModules: [ReaderFormatModule] = []

  init(delegate: ModuleDelegate?,
       resourcesServer: ResourcesServer,
       bookRegistry: TPPBookRegistryProvider) {
    self.delegate = delegate
    self.resourcesServer = resourcesServer
    self.bookRegistry = bookRegistry
    self.progressSynchronizer = TPPLastReadPositionSynchronizer(bookRegistry: bookRegistry)

    formatModules = [
      EPUBModule(delegate: self.delegate, resourcesServer: resourcesServer),
      PDFModule(delegate: self.delegate)
    ]
  }
  
  func presentPublication(_ publication: Publication,
                          book: TPPBook,
                          in navigationController: UINavigationController) {
    if delegate == nil {
      TPPErrorLogger.logError(nil, summary: "ReaderModule delegate is not set")
    }
    
    guard let formatModule = self.formatModules.first(where:{ $0.publicationFormats.contains(publication.format) }) else {
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
                                                           in: navigationController)
    }
  }

  func finalizePresentation(for publication: Publication,
                            book: TPPBook,
                            formatModule: ReaderFormatModule,
                            in navigationController: UINavigationController) {
    do {
      let lastSavedLocation = bookRegistry.location(forIdentifier: book.identifier)
      let initialLocator = lastSavedLocation?.convertToLocator()

      let readerVC = try formatModule.makeReaderViewController(
        for: publication,
        book: book,
        initialLocation: initialLocator)

      let backItem = UIBarButtonItem()
      backItem.title = NSLocalizedString("Back", comment: "Text for Back button")
      readerVC.navigationItem.backBarButtonItem = backItem
      readerVC.extendedLayoutIncludesOpaqueBars = true
      readerVC.hidesBottomBarWhenPushed = true
      navigationController.pushViewController(readerVC, animated: true)

    } catch {
      delegate?.presentError(error, from: navigationController)
    }
  }
}
