import SwiftUI

struct BorderStyleModifier: ViewModifier {
  func body(content: Content) -> some View {
    if UIDevice.current.userInterfaceIdiom == .pad {
      content
        .overlay(
          Rectangle()
            .stroke(Color.gray.opacity(0.5), lineWidth: 1.5)
        )
    } else {
      content
        .overlay(
          Rectangle()
            .frame(height: 1)
            .foregroundColor(Color.gray.opacity(0.5))
            .offset(y: 0.5),
          alignment: .bottom
        )
    }
  }
}
