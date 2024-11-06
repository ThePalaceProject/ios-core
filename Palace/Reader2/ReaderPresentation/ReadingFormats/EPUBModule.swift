//
//  EPUB.swift
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


final class EPUBModule: ReaderFormatModule {
  
  weak var delegate: ModuleDelegate?
  let resourcesServer: HTTPServer

  init(delegate: ModuleDelegate?, resourcesServer: HTTPServer) {
    self.delegate = delegate
    self.resourcesServer = resourcesServer
  }
    
  func supports(_ publication: Publication) -> Bool {
    // .allAreHTML matches .wepub format
    return publication.conforms(to: .epub) || publication.readingOrder.allAreHTML
  }

  func makeReaderViewController(for publication: Publication,
                                book: TPPBook,
                                initialLocation: Locator?,
                                forSample: Bool = false) throws -> UIViewController {

    guard publication.metadata.identifier != nil else {
      throw ReaderError.epubNotValid
    }

      let epubVC = try TPPEPUBViewController(publication: publication,
                                             book: book,
                                             initialLocation: initialLocation,
                                             resourcesServer: resourcesServer,
                                             forSample: forSample)
      epubVC.moduleDelegate = delegate
      return epubVC
    }
}
