import SwiftUI

struct FullScreenControllerWrapper: View {
  @EnvironmentObject private var coordinator: NavigationCoordinator
  let controller: UIViewController

  var body: some View {
    ZStack(alignment: .topTrailing) {
      UIViewControllerWrapper(controller, updater: { _ in })
        .ignoresSafeArea()
      Button(action: { coordinator.pop() }) {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.secondary)
          .imageScale(.large)
      }
      .padding(12)
      .accessibilityLabel("Close")
    }
    .navigationBarBackButtonHidden(true)
  }
}


