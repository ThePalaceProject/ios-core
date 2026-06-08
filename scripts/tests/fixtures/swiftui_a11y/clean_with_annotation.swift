// Fixture: clean-with-bare-text-but-annotation — same shape as violation.swift,
// no explicit a11y modifier, BUT each control is prefaced with a
// `// no-a11y-label: <reason>` annotation. Detector must emit ZERO findings.
import SwiftUI

struct CleanAnnotatedView: View {
    @State private var username: String = ""
    @State private var pin: String = ""

    var body: some View {
        VStack {
            // no-a11y-label: search field placeholder, see PP-9999 a11y audit deferral
            TextField("Search…", text: $username)
                .textContentType(.username)
            // no-a11y-label: PIN field semantics are covered by textContentType(.password)
            SecureField("PIN", text: $pin)
                .textContentType(.password)
            // no-a11y-label: button label "OK" is universally understood
            Button(action: { /* confirm */ }, label: {
                Text("OK")
            })
        }
    }
}
