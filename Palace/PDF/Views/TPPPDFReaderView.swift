//
//  TPPPDFReaderView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 14.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPPDFReaderView: View {
  
  typealias DisplayStrings = Strings.TPPLastReadPositionSynchronizer
  
  @EnvironmentObject var metadata: TPPPDFDocumentMetadata
  @State private var readerMode: TPPPDFReaderMode = .reader
  @State private var shouldRequestPageSync = false
  private var isShowingSearch: Bool {
    get { readerMode == .search }
  }

  let document: TPPPDFDocument
  
  var body: some View {
    TPPPDFNavigation(readerMode: $readerMode) { _ in
      ZStack {
        documentView
          .onReceive(metadata.$remotePage, perform: showRemotePositionAlert)
          .visible(when: readerMode == .reader || readerMode == .search)
          .alert(isPresented: $shouldRequestPageSync) {
            Alert(title: Text(DisplayStrings.syncReadingPositionAlertTitle),
                  message: Text(DisplayStrings.syncReadingPositionAlertBody),
                  primaryButton: .default(Text(DisplayStrings.move), action: metadata.syncReadingPosition),
                  secondaryButton: .cancel(Text(DisplayStrings.stay))
            )
          }


        TPPPDFPreviewGrid(document: document, pageIndices: nil, isVisible: readerMode == .previews, done: done)
          .visible(when: readerMode == .previews)
        bookmarkView
          .visible(when: readerMode == .bookmarks)
        TPPPDFTOCView(document: document, done: done)
          .visible(when: readerMode == .toc)
      }
      .sheet(isPresented: .constant(isShowingSearch)) {
        TPPPDFSearchView(document: document, done: done)
          .environmentObject(metadata) // iOS 13 crashes if metadata is not 
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
  var bookmarkView: some View {
    if !metadata.bookmarks.isEmpty {
      TPPPDFPreviewGrid(document: document, pageIndices: metadata.bookmarks, isVisible: readerMode == .bookmarks, done: done)
        .visible(when: readerMode == .bookmarks)
    } else {
      Text(NSLocalizedString("There are no bookmarks for this book.", comment: ""))
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
  
  /// Present navigation alert
  func showRemotePositionAlert(_ value: Published<Int?>.Publisher.Output) {
    if let value = value, metadata.currentPage != value {
      shouldRequestPageSync = true
    }
  }
}
