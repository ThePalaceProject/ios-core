// Fixture: violation — TextField + SecureField + Button with bare-string
// labels and NO `.accessibilityLabel` / `prompt:` override. Detector must
// emit D2-1 for the two field calls and D2-2 for the Button.
import SwiftUI

struct ViolationView: View {
    @State private var username: String = ""
    @State private var pin: String = ""

    var body: some View {
        VStack {
            TextField("Barcode or Username", text: $username)
                .textContentType(.username)
            SecureField("PIN", text: $pin)
                .textContentType(.password)
            Button(action: { /* sign in */ }, label: {
                Text("Sign In")
            })
        }
    }
}
