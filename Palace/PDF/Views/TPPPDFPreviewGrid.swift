//
//  TPPPDFPreviewGrid.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

struct TPPPDFPreviewGrid: UIViewControllerRepresentable {
  let document: TPPPDFDocument
  var pageIndices: [Int]?
  var isVisible = false
  let done: () -> Void
  
  @EnvironmentObject var metadata: TPPPDFDocumentMetadata

  func makeUIViewController(context: Context) -> some UIViewController {
    let vc = TPPPDFPreviewGridController(document: document, indices: pageIndices)
    vc.delegate = context.coordinator
    vc.currentPage = metadata.currentPage
    vc.isVisible = isVisible
    return vc
  }

  func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {
    guard let vc = uiViewController as? TPPPDFPreviewGridController else {
      return
    }
    vc.indices = pageIndices?.sorted()
    vc.currentPage = metadata.currentPage
    vc.isVisible = isVisible
  }

  func makeCoordinator() -> Coordinator {
    Coordinator { page in
      metadata.currentPage = page
      done()
    }
  }

  class Coordinator: TPPPDFPreviewGridDelegate {
    let action: (Int) -> Void

    func didSelectPage(_ n: Int) {
      action(n)
    }
    
    init(changePageAction: @escaping (Int) -> Void) {
      self.action = changePageAction
    }
  }
}
