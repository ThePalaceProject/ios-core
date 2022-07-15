//
//  TPPPDFThumbnailView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 08.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PDFKit

/// Wraps PDFKit PDFThumbnails control
struct TPPPDFThumbnailView: UIViewRepresentable {

  var pdfView: PDFView
  
  func makeUIView(context: Context) -> some UIView {
    let view = PDFThumbnailView()
    view.pdfView = pdfView
    view.layoutMode = .horizontal
    view.backgroundColor = .systemBackground
    return view
  }
  
  func updateUIView(_ uiView: UIViewType, context: Context) {
    //
  }
}
