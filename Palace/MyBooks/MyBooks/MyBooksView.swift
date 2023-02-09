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
          ZStack(alignment: .leading) {
            NavigationLink(destination: UIViewControllerWrapper(TPPBookDetailViewController(book: model.books[i]), updater: { _ in })) {
              EmptyView()
            }
            .opacity(0)
            BookCell(model: BookCellModel(book: model.books[i]))
          }
          .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
          .listRowBackground(Color.clear)
        }
      }
      .onAppear { model.reloadData() }
      .padding(.leading, -10)
  }
}

