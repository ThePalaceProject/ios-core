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
    let controller = UIHostingController(rootView: CatalogView(viewModel: viewModel))
    controller.title = NSLocalizedString("Catalog", comment: "") // used for tab bar label
    controller.tabBarItem.image = UIImage(named: "CatalogTab")
    let nav = UINavigationController(rootViewController: controller)
    nav.setNavigationBarHidden(true, animated: false)
    return nav
  }
}


