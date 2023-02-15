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
  @State var showLibraryAccountView: Bool = false {
    didSet {
      print("show library account view reset")
    }
  }

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
    .navigationBarItems(leading: leadingBarButton, trailing: trailingBarButton)
    .actionSheet(isPresented: $selectNewLibrary) {
      libraryPicker
    }
    .sheet(isPresented: $showLibraryAccountView) {
      libraryAccountView()
    }
    .alert(item: $model.alert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .cancel()
      )
    }
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
    SortView(
      model: model.facetViewModel
    )
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
  
  @ViewBuilder private var leadingBarButton: some View {
    Button {
      selectNewLibrary.toggle()
    } label: {
      ImageProviders.MyBooksView.myLibraryIcon
    }
  }
  
  @ViewBuilder private var trailingBarButton: some View {
    Button {
      print("Show mybooks search")
    } label: {
      ImageProviders.MyBooksView.search
    }
  }
  
  private var libraryPicker: ActionSheet {
    ActionSheet(
      title: Text(Strings.MyBooksView.findYourLibrary),
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
    .default(Text(Strings.MyBooksView.addLibrary)) {
      showLibraryAccountView = true
    }
  }
  
  private func libraryAccountView() -> some View {
     let accountList = TPPAccountList { account in
       model.authenticateAndLoad(account)
       showLibraryAccountView = false
       selectNewLibrary = false
     }
  
    return UIViewControllerWrapper(accountList, updater: {_ in })
  }
}
