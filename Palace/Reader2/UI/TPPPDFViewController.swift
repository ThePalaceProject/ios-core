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


@available(iOS 11.0, *)
final class TPPPDFViewController: TPPBaseReaderViewController {
  
  init(publication: Publication,
       book: TPPBook,
       initalLocator: Locator?) {
    
    let navigator = PDFNavigatorViewController(publication: publication,
                                               initialLocation: initalLocator,
                                               editingActions: [])
  
    super.init(navigator: navigator, publication: publication, book: book)
    navigator.delegate = self
  }

  override func viewDidLoad() {
    super.viewDidLoad()
  }
}

@available(iOS 11.0, *)
extension TPPPDFViewController: PDFNavigatorDelegate {
}

// MARK: - UIGestureRecognizerDelegate

extension TPPPDFViewController: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }
}
