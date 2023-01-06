//
//  MyBooksView.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine

struct MyBooksView: View {
  typealias DisplayStrings = Strings.MyBooksView
  @ObservedObject var model: MyBooksViewModel

  var body: some View {
    VStack(alignment: .leading) {
      facetView
      List {
        ForEach(model.books) {
          BookCell(book: $0)
        }
      }
    }
  }
  
  @ViewBuilder private var facetView: some View {
    FacetView(
      model: model.facetViewModel
    )
  }
}

