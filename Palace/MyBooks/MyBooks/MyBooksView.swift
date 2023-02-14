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
    NavigationView {
      ZStack {
        emptyView
        VStack(alignment: .leading) {
          facetView
          listView
        }
        loadingView
      }
    }
    .navigationViewStyle(.stack)
  }

 @ViewBuilder private var emptyView: some View {
    if model.books.count == 0 {
      Text(Strings.MyBooksView.emptyViewMessage)
        .multilineTextAlignment(.center)
        .foregroundColor(.gray)
        .horizontallyCentered()
    }
  }

  @ViewBuilder private var facetView: some View {
    FacetView(
      model: model.facetViewModel
    )
    .padding(.leading)
  }

  @ViewBuilder private var loadingView: some View {
    if model.isLoading {
      ProgressView()
        .scaleEffect(x: 2, y: 2, anchor: .center)
        .horizontallyCentered()
        .verticallyCentered()
    }
  }

  @ViewBuilder private var listView: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(0..<model.books.count, id: \.self) { i in
            ZStack(alignment: .leading) {
              NavigationLink(destination: UIViewControllerWrapper(TPPBookDetailViewController(book: model.books[i]), updater: { _ in })) {
                cell(for: model.books[i])
              }
            }
            .opacity(model.isLoading ? 0.5 : 1.0)
            .disabled(model.isLoading)
          }
        }
        .onAppear { model.reloadData() }
      }
  }

  private func cell(for book: TPPBook) -> BookCell {
    let model = BookCellModel(book: book)
    
    model
      .statePublisher.assign(to: \.isLoading, on: self.model)
      .store(in: &self.model.observers)
    return BookCell(model: model)
  }
}

extension UIDevice {
  var isLandscape: Bool {
    self.orientation == .landscapeLeft || self.orientation == .landscapeRight
  }
}
