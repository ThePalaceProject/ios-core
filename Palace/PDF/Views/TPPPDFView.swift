//
//  TPPPDFView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 31.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PDFKit

/// This view shows PDFKit views when PDF is not encrypted
/// PDFKit reading controls (PDFView and PDFThumbnails) are generally faster because of direct data reading,
/// instead of reading blocks of data with data provider.
/// The analog for encrypted documents - `TPPEncryptedPDFView`
struct TPPPDFView: View {
  
  let document: PDFDocument
  let pdfView = PDFView()
  private let pageChangePublisher = NotificationCenter.default.publisher(for: .PDFViewPageChanged)

  @EnvironmentObject var metadata: TPPPDFDocumentMetadata
  
  @State private var showingDocumentInfo = true
  @State private var isTracking = false

  var body: some View {
    ZStack {
      TPPPDFDocumentView(document: document, pdfView: pdfView, showingDocumentInfo: $showingDocumentInfo, isTracking: $isTracking)
        .edgesIgnoringSafeArea([.all])

      VStack {
        if let title = document.title ?? metadata.title {
          TPPPDFLabel(title)
            .padding(.top)
        }
        Spacer()
        if let pageLabel = document.page(at: metadata.currentPage)?.label, Int(pageLabel) != (metadata.currentPage + 1) {
          TPPPDFLabel("\(pageLabel) (\(metadata.currentPage + 1)/\(document.pageCount))")
        } else {
          TPPPDFLabel("\(metadata.currentPage + 1)/\(document.pageCount)")
        }
        VStack(spacing: 0) {
          Divider()
          TPPPDFThumbnailView(pdfView: pdfView)
            .frame(maxHeight: 40)
            .background(
              Color(UIColor.systemBackground)
                .edgesIgnoringSafeArea(.bottom)
            )
        }
      }
      .opacity(showingDocumentInfo ? 1 : 0)
      .contentShape(Rectangle())
    }
    .navigationBarHidden(!showingDocumentInfo)
    .onReceive(pageChangePublisher) { value in
      if let pdfView = (value.object as? PDFView), let page = pdfView.currentPage, let pageIndex = pdfView.document?.index(for: page) {
        metadata.currentPage = pageIndex
        if isTracking {
            showingDocumentInfo = false
        }
      }
    }
  }
}
