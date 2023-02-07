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
  @State private var selectedView: Int?

  var body: some View {
    VStack(alignment: .leading) {
      facetView
      listView
    }
  }

  @ViewBuilder private var facetView: some View {
    FacetView(
      model: model.facetViewModel
    )
  }

  @ViewBuilder private var listView: some View {
    List {
      ForEach(0..<model.books.count, id: \.self) { i in
        NavigationLink(
          destination: UIViewControllerWrapper(TPPBookDetailViewController(book: model.books[i]), updater: { _ in }),
          tag: i,
          selection: self.$selectedView
        ) {
          BookCell(model: BookCellModel(book: model.books[i]))
        }
        .listRowBackground(Color.clear)
      }
    }
  }
}

