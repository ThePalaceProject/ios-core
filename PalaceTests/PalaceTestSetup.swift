import Foundation

/// Registers NoNetworkURLProtocol at test bundle load time via NSPrincipalClass.
/// Any test that hits a real network endpoint (not localhost) will fail with
/// a clear message instead of silently making HTTP requests.
@objc(PalaceTestSetup)
final class PalaceTestSetup: NSObject {
    override init() {
        super.init()
        NoNetworkURLProtocol.enable()
    }
}
