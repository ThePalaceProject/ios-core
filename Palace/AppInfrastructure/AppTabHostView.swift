import SwiftUI
import UIKit

struct AppTabHostView: View {
  @StateObject private var router = AppTabRouter()
  @State private var holdsBadgeCount: Int = 0
  
  var body: some View {
    TabView(selection: $router.selected) {
      NavigationHostView(rootView: catalogView)
        .environmentObject(router)
        .tabItem {
          VStack {
            Image("Catalog").renderingMode(.template)
            Text(Strings.Settings.catalog)
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
        .badge(holdsBadgeCount)
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
      NotificationCenter.default.post(name: .AppTabSelectionDidChange, object: nil)
    }
    .onAppear {
      updateHoldsBadge()
    }
    .onReceive(NotificationCenter.default.publisher(for: .TPPBookRegistryStateDidChange)) { _ in
      updateHoldsBadge()
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

private extension AppTabHostView {
  func updateHoldsBadge() {
    let held = TPPBookRegistry.shared.heldBooks
    var readyCount = 0
    for book in held {
      book.defaultAcquisition?.availability.matchUnavailable(nil,
                                                            limited: nil,
                                                            unlimited: nil,
                                                            reserved: nil,
                                                            ready: { _ in readyCount += 1 })
    }
    holdsBadgeCount = readyCount
  }
}

extension Notification.Name {
  static let AppTabSelectionDidChange = Notification.Name("AppTabSelectionDidChange")
}

