import Foundation
import PalaceCatalog

/// Parses an Adobe DRM `*_rights.xml` file. Extracts the `display.until`
/// element from `licenseToken/permissions`.
///
/// Why: AdobeDRMContainer.mm (ObjC++) cannot directly use `TPPXML` from
/// the PalaceCatalog Swift package — `@import` does not resolve in C++
/// modules-disabled context, and class messages on a forward-declared
/// class fail. This Swift bridge isolates the package dependency so the
/// .mm file talks to a regular ObjC class instead.
@objc public final class AdobeRightsParser: NSObject {
    private let permissionsNode: TPPXML?

    @objc public init?(rightsData: Data) {
        guard let xml = TPPXML.xml(withData: rightsData) else { return nil }
        self.permissionsNode = xml.firstChild(withName: "licenseToken")?.firstChild(withName: "permissions")
        super.init()
        guard self.permissionsNode != nil else { return nil }
    }

    /// The `display.until` value as a raw string (RFC 3339-ish per the
    /// `*_rights.xml` schema). Caller is responsible for date parsing.
    @objc public var displayUntilString: String? {
        permissionsNode?.firstChild(withName: "display")?.firstChild(withName: "until")?.value
    }
}
