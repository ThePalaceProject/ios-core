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
  @State var selectNewLibrary: Bool = false
  @State var showLibraryAccountView: Bool = false

  var body: some View {
    NavigationLink(destination: searchView, isActive: $model.showSearchSheet) {}
    NavigationLink(destination: accountScreen, isActive: $model.showAccountScreen) {}
    
    NavigationView {
      ZStack {
        VStack(alignment: .leading) {
          facetView
          content
        }
        loadingView
      }
      .background(Color(TPPConfiguration.backgroundColor()))
    }
    .navigationBarItems(leading: leadingBarButton, trailing: trailingBarButton)
    .actionSheet(isPresented: $selectNewLibrary) {
      libraryPicker
    }
    .sheet(isPresented: $showLibraryAccountView) {
      accountPickerList
    }
    .alert(item: $model.alert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .cancel()
      )
    }
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
      ScrollView {
        if model.showInstructionsLabel {
          VStack {
            emptyView
          }
          .frame(minHeight: geometry.size.height)
        } else {
          listView
        }
      }
    }
  }
  
  @ViewBuilder private var listView: some View {
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
    .onAppear { model.loadData() }
  }
  
  private func cell(for book: TPPBook) -> BookCell {
    let model = BookCellModel(book: book)
    
    model
      .statePublisher.assign(to: \.isLoading, on: self.model)
      .store(in: &self.model.observers)
    return BookCell(model: model)
  }
  
  @ViewBuilder private var leadingBarButton: some View {
    Button {
      selectNewLibrary.toggle()
    } label: {
      ImageProviders.MyBooksView.myLibraryIcon
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
