//
//  TPPPDFReaderView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 14.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPPDFReaderView: View {
  
  @EnvironmentObject var metadata: TPPPDFDocumentMetadata
  @State private var readerMode: TPPPDFReaderMode = .reader
  private var isShowingSearch: Bool {
    get { readerMode == .search }
  }

  let document: TPPPDFDocument
  
  var body: some View {
    TPPPDFNavigation(readerMode: $readerMode) { _ in
      ZStack {
        documentView
          .visible(when: readerMode == .reader || readerMode == .search)
        TPPPDFPreviewGrid(document: document, pageIndices: nil, isVisible: readerMode == .previews, done: done)
          .visible(when: readerMode == .previews)
        TPPPDFPreviewGrid(document: document, pageIndices: metadata.bookmarks ?? [], isVisible: readerMode == .bookmarks, done: done)
          .visible(when: readerMode == .bookmarks)
        TPPPDFTOCView(document: document, done: done)
          .visible(when: readerMode == .toc)
      }
      .sheet(isPresented: .constant(isShowingSearch)) {
        TPPPDFSearchView(document: document, done: done)
      }
    }
    .navigationBarBackButtonHidden(true)
  }
  
  @ViewBuilder
  /// Document renderer
  var documentView: some View {
    if document.isEncrypted {
      if let encryptedDocument = document.encryptedDocument {
        TPPEncryptedPDFView(encryptedPDF: encryptedDocument)
      } else {
        unableToLoadView
      }
    } else {
      if let document = document.document {
        TPPPDFView(document: document)
      } else {
        unableToLoadView
      }
    }
  }
  
  @ViewBuilder
  var unableToLoadView: some View {
    Text("Unable to load PDF file")
  }
  
  /// Done picking a page
  func done() {
    readerMode = .reader
  }
}
