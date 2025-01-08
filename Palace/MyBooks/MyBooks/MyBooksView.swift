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
    .alert(item: $model.alert, content: createAlert)
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
      FacetView(model: model.facetViewModel)
      content
    }
  }

  private var searchBar: some View {
    HStack {
      TextField(DisplayStrings.searchBooks, text: $model.searchQuery)
        .searchBarStyle()
        .onChange(of: model.searchQuery, perform: model.filterBooks)
      Button(action: clearSearch, label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.gray)
      })
    }
    .padding(.horizontal)
  }

  private var content: some View {
    GeometryReader { geometry in
      if model.showInstructionsLabel {
        emptyView
          .frame(minHeight: geometry.size.height)
          .refreshable { model.reloadData() }
      } else {
        BookListView(
          books: model.books,
          isLoading: $model.isLoading,
          onSelect: { book in model.selectedBook = book }
        )
        .refreshable { model.reloadData() }
      }
    }
  }

  private func createAlert(_ alert: AlertModel) -> Alert {
    Alert(
      title: Text(alert.title),
      message: Text(alert.message),
      dismissButton: .cancel()
    )
  }

  private func clearSearch() {
    model.searchQuery = ""
    model.filterBooks(query: "")
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

  private var emptyView: some View {
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
    self.modifier(BorderStyleModifier())
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

extension View {
  func applyBorderStyle(index: Int, totalItems: Int) -> some View {
#if os(iOS)
    let isPhone = UIDevice.current.userInterfaceIdiom == .phone
#else
    let isPhone = false
#endif

    return self
      .if(!(isPhone && index == totalItems - 1)) { $0.borderStyle() }
  }

  @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
    if condition {
      transform(self)
    } else {
      self
    }
  }
}

struct BorderStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .border(
        width: 0.5,
        edges: edgesForDevice(),
        color: Color(TPPConfiguration.mainColor())
      )
  }

  private func edgesForDevice() -> [Edge] {
#if os(iOS)
    return UIDevice.current.userInterfaceIdiom == .phone ? [.bottom] : [.bottom, .trailing]
#else
    return [.bottom, .trailing]
#endif
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
  @Binding var isLoading: Bool
  let onSelect: (TPPBook) -> Void

  @State private var cancellables = Set<AnyCancellable>()

  var body: some View {
    AdaptableGridLayout {
      ForEach(Array(books.enumerated()), id: \.element.identifier) { index, book in
        let cellModel = BookCellModel(book: book)
        BookCell(model: cellModel)
          .applyBorderStyle(index: index, totalItems: books.count)
          .onAppear {
            observeCellLoadingState(cellModel)
          }
          .onTapGesture {
            onSelect(book)
          }
          .buttonStyle(.plain)
          .opacity(isLoading ? 0.5 : 1.0)
          .disabled(isLoading)
      }
    }
  }

  private func observeCellLoadingState(_ cellModel: BookCellModel) {
    cellModel.statePublisher
      .receive(on: DispatchQueue.main)
      .sink { isLoading in
        self.isLoading = isLoading
      }
      .store(in: &cancellables)
  }
}
