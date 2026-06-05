// Fixture: clean-with-accessibilityLabel — same shape as violation.swift but
// each control carries an explicit `.accessibilityLabel(...)` modifier within
// the downstream-cure window. Detector must emit ZERO findings.
import SwiftUI

struct CleanA11yView: View {
    @State private var username: String = ""
    @State private var pin: String = ""

    var body: some View {
        VStack {
            TextField("Barcode or Username", text: $username)
                .textContentType(.username)
                .accessibilityLabel(Text("Library card barcode"))
            SecureField("PIN", text: $pin)
                .textContentType(.password)
                .accessibilityLabel(Text("Personal identification number"))
            Button(action: { /* sign in */ }, label: {
                Text("Sign In")
            })
            .accessibilityLabel(Text("Sign in to your library account"))
        }
    }
}
