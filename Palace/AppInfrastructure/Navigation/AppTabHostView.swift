import SwiftUI

struct AppTabHostView: View {
  var body: some View {
    TabView {
      NavigationHostView(rootView: TPPCatalogHostViewController.makeSwiftUIViewSwiftUI())
        .tabItem { Label(NSLocalizedString("Catalog", comment: ""), image: "Catalog") }

      NavigationHostView(rootView: MyBooksView(model: MyBooksViewModel()))
        .tabItem { Label(Strings.MyBooksView.navTitle, image: "MyBooks") }

      NavigationHostView(rootView: HoldsView())
        .tabItem { Label(NSLocalizedString("Reservations", comment: ""), image: "Holds") }

      NavigationHostView(rootView: TPPSettingsView())
        .tabItem { Label(NSLocalizedString("Settings", comment: ""), systemImage: "gearshape") }
    }
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


