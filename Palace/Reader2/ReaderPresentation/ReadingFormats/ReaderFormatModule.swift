//
//  ReaderFormatModule.swift
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


/// A ReaderFormatModule handles presentation of publications in a
/// given format (eg. EPUB, CBZ).
protocol ReaderFormatModule {
  
  var delegate: ModuleDelegate? { get }
  
  /// Returns whether the given publication is supported by this module.
  func supports(_ publication: Publication) -> Bool

  /// Creates the view controller to present the publication.
  @MainActor
  func makeReaderViewController(for publication: Publication,
                                book: TPPBook,
                                initialLocation: Locator?,
                                forSample: Bool) throws -> UIViewController
  
}

