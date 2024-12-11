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
  @State private var searchQuery = ""
  @State var selectNewLibrary = false
  @State var showLibraryAccountView = false
  @State var showDetailForBook: TPPBook?

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: 0) {
        if model.showSearchSheet {
          searchBar
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        facetView
        content
      }
      .background(Color(TPPConfiguration.backgroundColor()))
      .navigationBarItems(leading: leadingBarButton, trailing: trailingBarButton)

      loadingView
    }
    .onAppear {
      model.showSearchSheet = false
    }
    .background(Color(TPPConfiguration.backgroundColor()))
    .alert(item: $model.alert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .cancel()
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  @ViewBuilder private var searchBar: some View {
    HStack {
      TextField(DisplayStrings.searchBooks, text: $searchQuery)
        .padding(8)
        .textFieldStyle(.automatic)
        .background(Color.gray.opacity(0.2))
        .cornerRadius(10)
        .padding(.vertical, 8)
        .onChange(of: searchQuery) { newQuery in
          filterBooks(with: newQuery)
        }
      Button(action: {
        searchQuery = ""
        filterBooks(with: "")
      }) {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.gray)
          .padding(.trailing, 8)
      }
    }
    .padding(.horizontal)
  }

  @ViewBuilder private var facetView: some View {
    FacetView(model: model.facetViewModel)
  }

  @ViewBuilder private var loadingView: some View {
    if model.isLoading {
      ProgressView()
        .scaleEffect(x: 2, y: 2, anchor: .center)
        .horizontallyCentered()
    }
  }

  @ViewBuilder private var emptyView: some View {
    Text(DisplayStrings.emptyViewMessage)
      .multilineTextAlignment(.center)
      .foregroundColor(.gray)
      .horizontallyCentered()
      .verticallyCentered()
      .palaceFont(.body)
  }

  @ViewBuilder private var content: some View {
    GeometryReader { geometry in
      if model.showInstructionsLabel {
        VStack {
          emptyView
        }
        .frame(minHeight: geometry.size.height)
        .refreshable {
          model.reloadData()
        }
      } else {
        listView
          .refreshable {
            model.reloadData()
          }
      }
    }
  }

  @ViewBuilder private var listView: some View {
    AdaptableGridLayout {
      ForEach(model.books, id: \.self) { book in
        ZStack(alignment: .leading) {
          cell(for: book)
        }
        .opacity(model.isLoading ? 0.5 : 1.0)
        .disabled(model.isLoading)
      }
    }
    .onAppear { model.loadData() }
  }

  private func filterBooks(with query: String) {
    if query.isEmpty {
      model.books = TPPBookRegistry.shared.myBooks
    } else {
      model.books = TPPBookRegistry.shared.myBooks.filter {
        $0.title.localizedCaseInsensitiveContains(query) || ($0.authors?.localizedCaseInsensitiveContains(query) ?? false)
      }
    }
  }

  private func cell(for book: TPPBook) -> some View {
    let model = BookCellModel(book: book)

    model
      .statePublisher.assign(to: \.isLoading, on: self.model)
      .store(in: &self.model.observers)

    if self.model.isPad {
      return Button {
        showDetailForBook = book
      } label: {
        BookCell(model: model)
          .border(width: 0.5, edges: [.bottom, .trailing], color: Color(TPPConfiguration.mainColor()))
      }
      .sheet(item: $showDetailForBook) { item in
        UIViewControllerWrapper(TPPBookDetailViewController(book: item), updater: { _ in })
      }
      .anyView()
    } else {
      return NavigationLink(destination: UIViewControllerWrapper(TPPBookDetailViewController(book: book), updater: { _ in })) {
        BookCell(model: model)
      }
      .anyView()
    }
  }

  private var leadingBarButton: some View {
    Button {
      selectNewLibrary.toggle()
    } label: {
      ImageProviders.MyBooksView.myLibraryIcon
    }
    .actionSheet(isPresented: $selectNewLibrary) {
      libraryPicker
    }
  }

  private var trailingBarButton: some View {
    Button {
      withAnimation {
        model.showSearchSheet.toggle()
      }
    } label: {
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
          showLibraryAccountView = false
          selectNewLibrary = false
        }
    }
  }

  private var addLibraryButton: Alert.Button {
    .default(Text(DisplayStrings.addLibrary)) {
      showLibraryAccountView = true
    }
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
