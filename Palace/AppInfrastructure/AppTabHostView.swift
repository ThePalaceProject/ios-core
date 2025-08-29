import SwiftUI

struct AppTabHostView: View {
  var body: some View {
    TabView {
      NavigationHostView(rootView: Self.catalogView())
        .tabItem { Label(NSLocalizedString("Catalog", comment: ""), image: "Catalog") }

      NavigationHostView(rootView: MyBooksView(model: MyBooksViewModel()))
        .tabItem { Label(Strings.MyBooksView.navTitle, image: "MyBooks") }

      NavigationHostView(rootView: HoldsView())
        .tabItem { Label(NSLocalizedString("Reservations", comment: ""), image: "Holds") }

      NavigationHostView(rootView: TPPSettingsView())
        .tabItem { Label(NSLocalizedString("Settings", comment: ""), systemImage: "gearshape") }
    }
  }
  
  @MainActor static func catalogView() -> some View {
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


