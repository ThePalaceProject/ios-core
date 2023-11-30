//
//  TPPPDFSearchView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import PalaceUIKit

/// Search view
struct TPPPDFSearchView: View {
  
  @ObservedObject var searchDelegate: SearchDelegate
  @EnvironmentObject var metadata: TPPPDFDocumentMetadata
  
  let document: TPPPDFDocument
  let done: () -> Void
  
  @State private var searchText = ""

  init(document: TPPPDFDocument, done: @escaping () -> Void) {
    self.document = document
    self.done = done
    self._searchDelegate = ObservedObject(wrappedValue: SearchDelegate(document: document))
  }
  
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button {
          done()
        } label: {
          Text(Strings.Generic.done)
            .palaceFont(.body, weight: .bold)
        }
        .padding()
      }
      Divider()
      TextField(Strings.Generic.search, text: $searchText.onChange(performSearch))
        .palaceFont(.body)
        .frame(minHeight: 44)
        .padding(.horizontal)
      Divider()
      List {
        ForEach(searchDelegate.searchResults) { location in
          TPPPDFLocationView(location: location)
            .onTapGesture {
              metadata.currentPage = location.pageNumber
              done()
            }
        }
      }
    }
  }
  
  func performSearch(string: String) {
    searchDelegate.search(text: string)
  }

  class SearchDelegate: ObservableObject, TPPPDFDocumentDelegate {
    
    let document: TPPPDFDocument
    
    @Published var searchResults: [TPPPDFLocation] = []

    init(document: TPPPDFDocument) {
      self.document = document
      self.document.delegate = self
    }
    
    func search(text: String) {
      searchResults = []
      if text.count >= 3 {
        document.search(text: text)
      }
    }
    
    func cancelSearch() {
      document.cancelSearch()
    }
    
    func didMatchString(_ instance: TPPPDFLocation) {
      searchResults.append(instance)
    }
  }
}
