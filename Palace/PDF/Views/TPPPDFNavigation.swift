//
//  TPPPDFNavigation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 15.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// Navigation between previews, TOC and bookmarks
struct TPPPDFNavigation<Content>: View where Content: View {
  
  private enum TPPPDFReaderModeValues: Int, Identifiable {
    case previews, toc, bookmarks
    
    var id: Int {
      rawValue
    }
    
    var image: Image {
      switch self {
      case .previews: return Image(systemName: "rectangle.grid.3x2")
      case .toc: return Image(systemName: "list.bullet")
      case .bookmarks: return Image(systemName: "bookmark")
      }
    }
    
    static var allValues: [TPPPDFReaderModeValues] {
      return [.previews, .toc, .bookmarks]
    }
    
    var readerMode: TPPPDFReaderMode {
      switch self {
      case .previews: return .previews
      case .toc: return .toc
      case .bookmarks: return .bookmarks
      }
    }
  }
  
  @EnvironmentObject var metadata: TPPPDFDocumentMetadata
  
  @Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
  
  @Binding var readerMode: TPPPDFReaderMode

  private var isShowingPdfContorls: Bool {
    readerMode == .previews || readerMode == .bookmarks || readerMode == .toc
  }
  @State private var pickerSelection = 0
  let content: (TPPPDFReaderMode) -> Content
  
  var body: some View {
    content(readerMode)
      .navigationBarItems(leading: leadingItems, trailing: trailingItems)
  }
  
  private let minButtonSize = CGSize(width: 24, height: 24)
  
  @ViewBuilder
  var leadingItems: some View {
    HStack {
      TPPPDFBackButton {
        presentationMode.wrappedValue.dismiss()
      }
      
      ZStack(alignment: .leading) {
        TPPPDFToolbarButton(icon: "list.bullet") {
          readerMode = TPPPDFReaderModeValues(rawValue: pickerSelection)?.readerMode ?? .previews
          metadata.fetchBookmarks()
        }
        .visible(when: !isShowingPdfContorls)

        Picker("", selection: $pickerSelection.onChange(changeReaderMode)) {
          ForEach(TPPPDFReaderModeValues.allValues) { readerModeValue in
            readerModeValue.image
              .tag(readerModeValue.rawValue)
          }
        }
        .toolbarButtonSize()
        .pickerStyle(.segmented)
        .visible(when: isShowingPdfContorls)
      }
    }
  }

  @ViewBuilder
  var trailingItems: some View {
    ZStack(alignment: .trailing) {
      TPPPDFToolbarButton(text: "Resume") {
        readerMode = .reader
      }
      .visible(when: isShowingPdfContorls)

      HStack {
        TPPPDFToolbarButton(icon: "magnifyingglass") {
          readerMode = (readerMode == .search ? .reader : .search)
        }
        TPPPDFToolbarButton(icon: metadata.isBookmarked() ? "bookmark.fill" : "bookmark") {
          if metadata.isBookmarked() {
            metadata.removeBookmark()
          } else {
            metadata.addBookmark()
          }
        }
      }
      .visible(when: !isShowingPdfContorls)
    }
  }

  func changeReaderMode(_ newValue: Int) {
    if let readerModeValue = TPPPDFReaderModeValues(rawValue: newValue) {
      readerMode = readerModeValue.readerMode
    }
  }
}
