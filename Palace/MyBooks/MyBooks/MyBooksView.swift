//
//  MyBooksView.swift
//  Palace
//
//  Created by Maurice Carrier on 12/23/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine
import PalaceUIKit

struct MyBooksView: View {
  typealias DisplayStrings = Strings.MyBooksView
  @ObservedObject var model: MyBooksViewModel

  var body: some View {
    ZStack {
      mainContent
      if model.isLoading { loadingOverlay }
    }
    .background(Color(TPPConfiguration.backgroundColor()))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) { leadingBarButton }
      ToolbarItem(placement: .navigationBarTrailing) { trailingBarButton }
    }
    .onAppear { model.showSearchSheet = false }
    .alert(item: $model.alert) { alert in
      createAlert(alert)
    }
    .sheet(item: $model.selectedBook) { book in
      UIViewControllerWrapper(TPPBookDetailViewController(book: book), updater: { _ in })
        .onDisappear {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            model.selectedBook = nil
          }
        }
    }
  }

  private var mainContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.showSearchSheet { searchBar }
      facetView
      content
    }
  }

  @ViewBuilder private var searchBar: some View {
    HStack {
      TextField(DisplayStrings.searchBooks, text: $model.searchQuery)
        .searchBarStyle()
        .onChange(of: model.searchQuery, perform: model.filterBooks)
      clearSearchButton
    }
    .padding(.horizontal)
  }

  private var clearSearchButton: some View {
    Button(action: {
      model.searchQuery = ""
      model.filterBooks(query: "")
    }) {
      Image(systemName: "xmark.circle.fill")
        .foregroundColor(.gray)
    }
  }

  @ViewBuilder private var facetView: some View {
    FacetView(model: model.facetViewModel)
  }

  @ViewBuilder private var content: some View {
    GeometryReader { geometry in
      if model.showInstructionsLabel {
        VStack {
          emptyView
        }
        .frame(minHeight: geometry.size.height)
        .refreshable { model.reloadData() }
      } else {
        listView
          .refreshable { model.reloadData() }
      }
    }
  }

  private var listView: some View {
    BookListView(
      books: model.books,
      isLoading: model.isLoading,
      onSelect: { book in model.selectedBook = book }
    )
    .onAppear { model.loadData() }
  }

  private func createAlert(_ alert: AlertModel) -> Alert {
    Alert(
      title: Text(alert.title),
      message: Text(alert.message),
      dismissButton: .cancel()
    )
  }

  private var loadingOverlay: some View {
    ProgressView()
      .scaleEffect(2)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.5).ignoresSafeArea())
  }

  private var leadingBarButton: some View {
    Button(action: { model.selectNewLibrary.toggle() }) {
      ImageProviders.MyBooksView.myLibraryIcon
    }
    .actionSheet(isPresented: $model.selectNewLibrary) { libraryPicker }
  }

  private var trailingBarButton: some View {
    Button(action: { withAnimation { model.showSearchSheet.toggle() } }) {
      ImageProviders.MyBooksView.search
    }
  }

  private var libraryPicker: ActionSheet {
    ActionSheet(
      title: Text(DisplayStrings.findYourLibrary),
      buttons: existingLibraryButtons() + [addLibraryButton, .cancel()]
    )
  }

  private func existingLibraryButtons() -> [ActionSheet.Button] {
    TPPSettings.shared.settingsAccountsList.map { account in
        .default(Text(account.name)) {
          model.loadAccount(account)
          model.showLibraryAccountView = false
          model.selectNewLibrary = false
        }
    }
  }

  private var addLibraryButton: ActionSheet.Button {
    .default(Text(DisplayStrings.addLibrary)) { model.showLibraryAccountView = true }
  }

  @ViewBuilder private var emptyView: some View {
    Text(DisplayStrings.emptyViewMessage)
      .multilineTextAlignment(.center)
      .foregroundColor(.gray)
      .centered()
      .palaceFont(.body)
  }
}

extension View {
  func searchBarStyle() -> some View {
    self.padding(8)
      .textFieldStyle(.automatic)
      .background(Color.gray.opacity(0.2))
      .cornerRadius(10)
      .padding(.vertical, 8)
  }

  func borderStyle() -> some View {
    self.border(width: 0.5, edges: [.bottom, .trailing], color: Color(TPPConfiguration.mainColor()))
  }

  func centered() -> some View {
    self.horizontallyCentered().verticallyCentered()
  }
}

extension View {
  func border(width: CGFloat, edges: [Edge], color: Color) -> some View {
    overlay(EdgeBorder(width: width, edges: edges).foregroundColor(color))
  }
}

struct EdgeBorder: Shape {
  var width: CGFloat
  var edges: [Edge]

  func path(in rect: CGRect) -> Path {
    var path = Path()
    for edge in edges {
      var x: CGFloat {
        switch edge {
        case .top, .bottom, .leading: return rect.minX
        case .trailing: return rect.maxX - width
        }
      }

      var y: CGFloat {
        switch edge {
        case .top, .leading, .trailing: return rect.minY
        case .bottom: return rect.maxY - width
        }
      }

      var w: CGFloat {
        switch edge {
        case .top, .bottom: return rect.width
        case .leading, .trailing: return width
        }
      }

      var h: CGFloat {
        switch edge {
        case .top, .bottom: return width
        case .leading, .trailing: return rect.height
        }
      }
      path.addRect(CGRect(x: x, y: y, width: w, height: h))
    }
    return path
  }
}

struct BookListView: View {
  let books: [TPPBook]
  let isLoading: Bool
  let onSelect: (TPPBook) -> Void

  var body: some View {
    AdaptableGridLayout {
      ForEach(books, id: \.identifier) { book in
        Button {
          onSelect(book)
        } label: {
          BookCell(model: BookCellModel(book: book))
            .borderStyle()
        }
        .buttonStyle(.plain)
        .opacity(isLoading ? 0.5 : 1.0)
        .disabled(isLoading)
      }
    }
  }
}
