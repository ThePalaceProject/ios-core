// Fixture: false-positive-immunity — Buttons whose Text contains a long
// sentence (clearly main-UI body copy, not a placeholder/short label).
// Detector must emit ZERO findings because the literal length exceeds the
// _PLACEHOLDER_LITERAL_MAX threshold.
import SwiftUI

struct LongCopyView: View {
    var body: some View {
        VStack(spacing: 16) {
            Button(action: { /* tap */ }, label: {
                Text("By signing in you agree to our Terms of Service and Privacy Policy")
            })
            // TextField with a long literal label (also exempt by length).
            TextField("Enter your library card barcode number including the leading zero", text: .constant(""))
            // Plain Text() body copy — not in a Button label position, so
            // never a candidate regardless of length.
            Text("Welcome to Palace")
        }
    }
}
