//
//  PDFModule.swift
//  Palace
//
//  Created by Maurice Carrier on 3/24/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import R2Navigator
import R2Shared

/// The PDF module is only available on iOS 11 and more, since it relies on PDFKit.
@available(iOS 11.0, *)
final class PDFModule: ReaderFormatModule {

    weak var delegate: ModuleDelegate?
    
    init(delegate: ModuleDelegate?) {
        self.delegate = delegate
    }
    
    var publicationFormats: [Publication.Format] {
        return [.pdf]
    }

  func makeReaderViewController(for publication: Publication,
                                book: TPPBook,
                                initialLocation: Locator?) throws -> UIViewController {
    let viewController = TPPPDFViewController(publication: publication, book: book, initalLocator: initialLocation)
    viewController.moduleDelegate = delegate
    return viewController
  }
}
