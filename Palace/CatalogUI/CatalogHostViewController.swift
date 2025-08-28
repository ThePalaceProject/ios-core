import Foundation
import SwiftUI

@objc class TPPCatalogHostViewController: NSObject {
  @MainActor @objc static func makeSwiftUIView() -> UIViewController {
    let client = URLSessionNetworkClient()
    let parser = OPDSParser()
    let api = DefaultCatalogAPI(client: client, parser: parser)
    let repository = CatalogRepository(api: api)
    let viewModel = CatalogViewModel(repository: repository) {
      TPPSettings.shared.accountMainFeedURL
    }
    let hosting = UIHostingController(rootView: CatalogView(viewModel: viewModel))
    hosting.title = nil
    hosting.tabBarItem.title = NSLocalizedString("Catalog", comment: "")
    hosting.tabBarItem.image = UIImage(named: "Catalog")
    hosting.navigationItem.largeTitleDisplayMode = .never

    let nav = UINavigationController(rootViewController: hosting)
    nav.navigationBar.prefersLargeTitles = false
    nav.setNavigationBarHidden(false, animated: false)
    return nav
  }
}


