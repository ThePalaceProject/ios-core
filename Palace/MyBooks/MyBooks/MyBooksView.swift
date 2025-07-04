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
      .navigationTitle(DisplayStrings.navTitle)
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarHidden(false)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) { leadingBarButton }
        ToolbarItem(placement: .navigationBarTrailing) { trailingBarButton }
      }
      .onAppear {
        model.showSearchSheet = false
        UITabBarController.showFloatingTabBar()
      }
      .sheet(isPresented: $model.showLibraryAccountView) {
        UIViewControllerWrapper(
          TPPAccountList { account in
            model.authenticateAndLoad(account: account)
            model.showLibraryAccountView = false
          },
          updater: { _ in }
        )
      }
  }

  private var mainContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.showSearchSheet { searchBar }
      FacetView(model: model.facetViewModel)
      content
    }
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
          onSelect: { book in presentBookDetail(for: book) }
        )
        .refreshable { model.reloadData() }
      }
    }
  }

  private func presentBookDetail(for book: TPPBook) {
    let detailVC = BookDetailHostingController(book: book)
    TPPRootTabBarController.shared().pushViewController(detailVC, animated: true)
  }

  private var searchBar: some View {
    HStack {
      TextField(DisplayStrings.searchBooks, text: $model.searchQuery)
        .searchBarStyle()
        .onChange(of: model.searchQuery) { query in
          Task {
            await model.filterBooks(query: query)
          }
        }
      Button(action: clearSearch, label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.gray)
      })
    }
    .padding(.horizontal)
  }

  private func clearSearch() {
    Task {
      model.searchQuery = ""
      await model.filterBooks(query: "")
    }
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

  private func setupTabBarForiPad() {
#if os(iOS)
    if UIDevice.current.userInterfaceIdiom == .pad {
      UITabBar.appearance().isHidden = false
    }
#endif
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

  func centered() -> some View {
    self.horizontallyCentered().verticallyCentered()
  }
}
