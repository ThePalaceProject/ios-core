//
//  TPPPDFSearchView.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

struct TPPPDFSearchView: View {
  
  let document: TPPPDFDocument
  
  @State private var searchText = ""
  @State private var searchResults: [TPPPDFLocation] = []
  
  var body: some View {
    VStack {
      TextField("Search", text: $searchText.onChange({ value in
        performSearch(string: value)
      }))
      .padding()
      Divider()
      List {
        ForEach(searchResults) { location in
          TPPPDFLocationView(location: location)
        }
      }
    }
  }
  
  func performSearch(string: String) {
    searchResults = document.search(text: string)
  }
}
