import SwiftUI

struct AppTabHostView: View {
  @StateObject private var router = AppTabRouter()
  
  var body: some View {
    TabView(selection: $router.selected) {
      NavigationHostView(rootView: TPPCatalogHostViewController.makeSwiftUIViewSwiftUI())
        .tabItem {
          VStack {
            Image("Catalog").renderingMode(.template)
            Text(NSLocalizedString("Catalog", comment: ""))
          }
        }
        .tag(AppTab.catalog)

      NavigationHostView(rootView: MyBooksView(model: MyBooksViewModel()))
        .tabItem {
          VStack {
            Image("MyBooks").renderingMode(.template)
            Text(Strings.MyBooksView.navTitle)
          }
        }
        .tag(AppTab.myBooks)

      NavigationHostView(rootView: HoldsView())
        .tabItem {
          VStack {
            Image("Holds").renderingMode(.template)
            Text(NSLocalizedString("Reservations", comment: ""))
          }
        }
        .tag(AppTab.holds)

      NavigationHostView(rootView: TPPSettingsView())
        .tabItem { Label(NSLocalizedString("Settings", comment: ""), systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .tint(Color.accentColor)
    .onAppear { AppTabRouterHub.shared.router = router }
  }
}

private extension TPPCatalogHostViewController {
  @MainActor static func makeSwiftUIViewSwiftUI() -> some View {
    let client = URLSessionNetworkClient()
    let parser = OPDSParser()
    let api = DefaultCatalogAPI(client: client, parser: parser)
    let repository = CatalogRepository(api: api)
    let viewModel = CatalogViewModel(repository: repository) {
      TPPSettings.shared.accountMainFeedURL
    }
    return CatalogView(viewModel: viewModel)
  }
}


