import SwiftUI
import UIKit

struct HoldsView: View {
  @EnvironmentObject private var coordinator: NavigationCoordinator
  typealias DisplayStrings = Strings.HoldsView
  
  @StateObject private var model = HoldsViewModel()
  private var allBooks: [TPPBook] {
    model.reservedBookVMs.map { $0.book } + model.heldBookVMs.map { $0.book }
  }
  var body: some View {
    ZStack {
      VStack(spacing: 0) {

        if model.isLoading {
          BookListSkeletonView(rows: 10, imageSize: CGSize(width: 100, height: 150))
        } else if allBooks.isEmpty {
          Spacer()
          emptyView
          Spacer()
        } else {
          ScrollView {
            BookListView(
              books: allBooks,
              isLoading: $model.isLoading,
              onSelect: { book in presentBookDetail(book) }
            )
            .padding(.horizontal, 8)
          }
        }
      }
      .padding(.top, 100)
      .background(Color(TPPConfiguration.backgroundColor()))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          LibraryNavTitleView(onTap: {
            if let urlString = AccountsManager.shared.currentAccount?.homePageUrl, let url = URL(string: urlString) {
              UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
          })
        }
        ToolbarItem(placement: .navigationBarLeading) { leadingBarButton }
        ToolbarItem(placement: .navigationBarTrailing) { trailingBarButton }
      }
      .onAppear {
        model.showSearchView = false
        model.showLibraryAccountView = false
      }
      .refreshable {
        model.refresh()
      }
      .sheet(isPresented: $model.showLibraryAccountView) {
        UIViewControllerWrapper(
          TPPAccountList { account in
            model.loadAccount(account)
          },
          updater: { _ in }
        )
      }
      
      if model.isLoading {
        loadingOverlay
      }
    }
    .sheet(isPresented: $model.showSearchView) {
      let books = allBooks
      CatalogSearchView(books: books)
    }
  }
  
  /// Placeholder text when there are no holds at all
  private var emptyView: some View {
    Text(DisplayStrings.emptyMessage)
    .multilineTextAlignment(.center)
    .foregroundColor(Color(white: 0.667))
    .background(Color(TPPConfiguration.backgroundColor()))
    .font(.system(size: 18))
    .padding(.horizontal, 24)
  }
  
  /// Semi‐transparent loading overlay
  private var loadingOverlay: some View {
    ProgressView()
      .scaleEffect(2)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.5).ignoresSafeArea())
  }
  
  /// Leading bar button: “Pick a new library”
  private var leadingBarButton: some View {
    Button {
      model.selectNewLibrary = true
    } label: {
      ImageProviders.MyBooksView.myLibraryIcon
    }
    .actionSheet(isPresented: $model.selectNewLibrary) {
      var buttons: [ActionSheet.Button] = TPPSettings.shared.settingsAccountsList.map { account in
          .default(Text(account.name)) {
            model.loadAccount(account)
          }
      }
      buttons.append(.cancel())
      return ActionSheet(
        title: Text(NSLocalizedString(DisplayStrings.findYourLibrary, comment: "")),
        buttons: buttons
      )
    }
  }
  
  private var trailingBarButton: some View {
    Button {
      let books = allBooks
      let route = coordinator.storeSearchBooks(books)
      coordinator.push(.search(route))
    } label: {
      ImageProviders.MyBooksView.search
    }
    .accessibilityLabel(NSLocalizedString("Search Reservations", comment: ""))
  }
  
  private func presentBookDetail(_ book: TPPBook) {
    coordinator.store(book: book)
    coordinator.push(.bookDetail(BookRoute(id: book.identifier)))
  }
}

@objc final class TPPHoldsViewController: NSObject {
  
  /// Returns a `UINavigationController` containing our SwiftUI `HoldsView`.
  /// • The SwiftUI view uses `HoldsViewModel()` under the hood.
  /// • We set the navigation title and the tab-bar image here.
  @MainActor
  @objc static func makeSwiftUIView() -> UIViewController {
    let holdsRoot = HoldsView()
    
    let hosting = UIHostingController(rootView: holdsRoot)
    hosting.title = NSLocalizedString("Reservations", comment: "Nav title for Holds")
    hosting.tabBarItem.image = UIImage(named: "Holds")
    
    return hosting
  }
}
