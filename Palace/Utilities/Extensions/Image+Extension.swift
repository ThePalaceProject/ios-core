import SwiftUI

extension Image {
  func toUIImage() -> UIImage? {
    let controller = UIHostingController(rootView: resizable())
    let view = controller.view

    view?.bounds = CGRect(x: 0, y: 0, width: 300, height: 300) // Adjust size as needed
    view?.backgroundColor = .clear

    let renderer = UIGraphicsImageRenderer(size: view?.bounds.size ?? .zero)

    return renderer.image { _ in
      view?.drawHierarchy(in: view?.bounds ?? .zero, afterScreenUpdates: true)
    }
  }
}
