//
//  TPPR3Owner.swift
//
//  Created by Mickaël Menu on 20.02.19.
//
//  Copyright 2019 European Digital Reading Lab. All rights reserved.
//  Licensed to the Readium Foundation under one or more contributor license agreements.
//  Use of this source code is governed by a BSD-style license which is detailed in the
//  LICENSE file present in the project repository where this source code is maintained.
//

import Foundation
import UIKit
import ReadiumShared
import ReadiumStreamer

/// This class is the main root of R3 objects. It:
/// - owns the sub-modules (library, reader, etc.)
/// - orchestrates the communication between its sub-modules, through the
/// modules' delegates.
@objc public final class TPPR3Owner: NSObject {

  var libraryService: LibraryService! = nil
  var readerModule: ReaderModuleAPI! = nil

  override init() {
    super.init()
    libraryService = LibraryService()
    readerModule = ReaderModule(delegate: self,
                                resourcesServer: libraryService.httpServer,
                                bookRegistry: TPPBookRegistry.shared)

    ReadiumEnableLog(withMinimumSeverityLevel: .debug)
  }

  deinit {
    Log.warn(#file, "TPPR3Owner being dealloced")
  }
}

extension TPPR3Owner: ModuleDelegate {
  func presentAlert(_ title: String,
                    message: String,
                    from viewController: UIViewController) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    let dismissButton = UIAlertAction(title: Strings.Generic.ok, style: .cancel)
    alert.addAction(dismissButton)
    viewController.present(alert, animated: true)
  }

  func presentError(_ error: Error?, from viewController: UIViewController) {
    guard let error = error else { return }
    presentAlert(
      Strings.Generic.error,
      message: error.localizedDescription,
      from: viewController
    )
  }
}
