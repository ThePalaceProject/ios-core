//
//  TPPPDFView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 31.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PDFKit

struct TPPPDFView: View {
  
  let document: PDFDocument
  let pdfView = PDFView()

  @EnvironmentObject var metadata: TPPPDFDocumentMetadata
  
  @State private var showingDocumentInfo = true

  var body: some View {
    ZStack {
      TPPPDFDocumentView(document: document, pdfView: pdfView, showingDocumentInfo: $showingDocumentInfo)
        .edgesIgnoringSafeArea([.all])

      VStack {
        if let title = document.title ?? metadata.title {
          TPPPDFLabel(title)
            .padding(.top)
        }
        Spacer()
        TPPPDFLabel("\(metadata.currentPage + 1)/\(document.pageCount)")
        TPPPDFThumbnailView(pdfView: pdfView)
          .frame(maxHeight: 40)
          .background(
            Color(UIColor.systemBackground)
              .edgesIgnoringSafeArea(.bottom)
          )
      }
      .opacity(showingDocumentInfo ? 1 : 0)
      .contentShape(Rectangle())
    }
    .navigationBarHidden(!showingDocumentInfo)
  }
}
