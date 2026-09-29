//
//  TPPPDFTOCView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// TOC View
struct TPPPDFTOCView: View {

    @EnvironmentObject var metadata: TPPPDFDocumentMetadata
    let document: TPPPDFDocument
    let done: () -> Void

    var body: some View {
        VStack {
            List {
                ForEach(document.tableOfContents) { location in
                    // A real Button, not a tap gesture: VoiceOver announces the
                    // entry as a button and Full Keyboard Access can focus it,
                    // which is how a patron moves through the table of contents.
                    Button {
                        metadata.currentPage = location.pageNumber
                        done()
                    } label: {
                        TPPPDFLocationView(location: location, emphasizeLevel: 0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
