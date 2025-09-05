import SwiftUI
import UIKit

struct AppTabHostView: View {
  @StateObject private var router = AppTabRouter()
  
  var body: some View {
    TabView(selection: $router.selected) {
      NavigationHostView(rootView: catalogView)
        .tabItem {
          VStack {
            Image("Catalog").renderingMode(.template)
            Text(Strings.Settings.libraries) // Catalog label; consider a dedicated Strings.Catalog.catalog if desired
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
            Text(Strings.HoldsView.reservations)
          }
        }
        .tag(AppTab.holds)

      NavigationHostView(rootView: TPPSettingsView())
        .tabItem { Label(Strings.Settings.settings, systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .tint(Color.accentColor)
    .onAppear { AppTabRouterHub.shared.router = router }
    .onChange(of: router.selected) { _ in
      withAnimation(.easeInOut) {
        NavigationCoordinatorHub.shared.coordinator?.popToRoot()
      }
      if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate,
         let top = appDelegate.topViewController() {
        top.dismiss(animated: true)
      }
    }
  }

  var catalogView: some View {
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

