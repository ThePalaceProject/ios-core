//
//  TPPPDFThumbnailView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 08.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import PDFKit
import SwiftUI

/// Wraps PDFKit PDFThumbnails control
struct TPPPDFThumbnailView: UIViewRepresentable {
  var pdfView: PDFView

  func makeUIView(context _: Context) -> some UIView {
    let view = PDFThumbnailView()
    view.pdfView = pdfView
    view.layoutMode = .horizontal
    view.backgroundColor = .systemBackground
    return view
  }

  func updateUIView(_: UIViewType, context _: Context) {
    //
  }
}
