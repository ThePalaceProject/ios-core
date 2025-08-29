//import Foundation
//import SwiftUI
//
//@objc class TPPCatalogHostViewController: NSObject {
//  @MainActor @objc static func makeSwiftUIView() -> UIViewController {
//    let client = URLSessionNetworkClient()
//    let parser = OPDSParser()
//    let api = DefaultCatalogAPI(client: client, parser: parser)
//    let repository = CatalogRepository(api: api)
//    let viewModel = CatalogViewModel(repository: repository) {
//      TPPSettings.shared.accountMainFeedURL
//    }
//    let hosting = UIHostingController(rootView: NavigationHostView(rootView: CatalogView(viewModel: viewModel)))
//    hosting.title = nil
//    hosting.tabBarItem.title = NSLocalizedString("Catalog", comment: "")
//    hosting.tabBarItem.image = UIImage(named: "Catalog")
//    hosting.navigationItem.largeTitleDisplayMode = .never
//    return hosting
//  }
//}
//
//
