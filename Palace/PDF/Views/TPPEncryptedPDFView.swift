//
//  TPPEncryptedPDFView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 20.05.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// This view shows encrypted PDF documents.
/// The analog for non-encrypted documents - `TPPPDFView`
struct TPPEncryptedPDFView: View {
  let encryptedPDF: TPPEncryptedPDFDocument

  @EnvironmentObject var metadata: TPPPDFDocumentMetadata

  @State private var showingDocumentInfo = true

  var body: some View {
    ZStack {
      TPPEncryptedPDFViewer(
        encryptedPDF: encryptedPDF,
        currentPage: $metadata.currentPage,
        showingDocumentInfo: $showingDocumentInfo
      )
      .edgesIgnoringSafeArea([.all])
      VStack {
        TPPPDFLabel(encryptedPDF.title ?? metadata.book.title)
          .padding(.top)
        Spacer()
        TPPPDFLabel("\(metadata.currentPage + 1)/\(encryptedPDF.pageCount)")
        TPPPDFPreviewBar(document: encryptedPDF, currentPage: $metadata.currentPage)
      }
      .opacity(showingDocumentInfo ? 1 : 0)
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        // TPPEncryptedPDFPageViewController doesn't receive double tap without this
      }
      .onTapGesture(count: 1) {
        showingDocumentInfo.toggle()
      }
    }
    .navigationBarHidden(!showingDocumentInfo)
  }
}
