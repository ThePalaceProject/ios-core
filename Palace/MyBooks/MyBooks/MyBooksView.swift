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
  @State var selectNewLibrary = false
  @State var showLibraryAccountView = false
  @State var showDetailForBook: TPPBook?

  var body: some View {
    NavigationLink(destination: accountScreen, isActive: $model.showAccountScreen) {}
    NavigationLink(destination: searchView, isActive: $model.showSearchSheet) {}
    
    //TODO: This is a workaround for an apparent bug in iOS14 that prevents us from wrapping
    // the body in a NavigationView. Once iOS14 support is dropped, this can be removed/repalced
    // with a NavigationView
    EmptyView()
      .alert(item: $model.alert) { alert in
        Alert(
          title: Text(alert.title),
          message: Text(alert.message),
          dismissButton: .cancel()
        )
      }
      .sheet(isPresented: $showLibraryAccountView) {
        accountPickerList
      }
    
    ZStack {
      VStack(alignment: .leading) {
        facetView
        content
      }
      .background(Color(TPPConfiguration.backgroundColor()))
      .navigationBarItems(leading: leadingBarButton, trailing: trailingBarButton)
      loadingView
    }
    .background(Color(TPPConfiguration.backgroundColor()))
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
      ForEach(0..<model.books.count, id: \.self) { i in
        ZStack(alignment: .leading) {
            cell(for: model.books[i])
        }
        .opacity(model.isLoading ? 0.5 : 1.0)
        .disabled(model.isLoading)
      }
    }
    .onAppear { model.loadData() }
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
          .padding()
          .border(self.model.isPad ? Color(TPPConfiguration.mainColor()) : .clear)
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
  
  @ViewBuilder private var leadingBarButton: some View {
    Button {
      selectNewLibrary.toggle()
    } label: {
      ImageProviders.MyBooksView.myLibraryIcon
    }
    .actionSheet(isPresented: $selectNewLibrary) {
      libraryPicker
    }
  }
  
  @ViewBuilder private var trailingBarButton: some View {
    Button {
      model.showSearchSheet.toggle()
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
  
  private var accountPickerList: some View {
    let accountList = TPPAccountList { account in
      model.authenticateAndLoad(account)
      showLibraryAccountView = false
      selectNewLibrary = false
    }
    
    return UIViewControllerWrapper(accountList, updater: {_ in })
  }
  
  private var searchView: some View {
    let searchDescription = TPPOpenSearchDescription(title: DisplayStrings.searchBooks, books: model.books)
    let navController = UINavigationController(rootViewController: TPPCatalogSearchViewController(openSearchDescription: searchDescription))
    return UIViewControllerWrapper(navController, updater: { _ in })
  }
  
  private var accountScreen: some View {
    guard let url = model.accountURL else {
      return EmptyView().anyView()
    }
    
    let webController = BundledHTMLViewController(fileURL: url, title: "TEST")
    webController.hidesBottomBarWhenPushed = true
    return  UIViewControllerWrapper(webController, updater: { _ in } ).anyView()
  }
}
