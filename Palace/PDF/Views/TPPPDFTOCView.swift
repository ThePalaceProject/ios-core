//
//  TPPPDFTOCView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPPDFTOCView: View {

  @EnvironmentObject var metadata: TPPPDFDocumentMetadata
  let document: TPPPDFDocument

  var body: some View {
    VStack {
      List {
        ForEach(document.tableOfContents) { location in
          TPPPDFLocationView(location: location)
            .onTapGesture {
              metadata.currentPage = location.pageNumber
            }
        }
      }
    }
  }
}
