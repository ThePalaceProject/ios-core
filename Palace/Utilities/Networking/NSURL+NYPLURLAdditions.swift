import Foundation

extension URL {

  /// Returns `true` if the URL points to an external resource (not file, not localhost, not about:).
  var isNYPLExternal: Bool {
    if isFileURL { return false }
    if scheme == "about" { return false }
    if let host = host, ["127.0.0.1", "::1", "localhost"].contains(host) { return false }
    return true
  }

  /// Returns a new URL with the given scheme swapped in.
  func swappingScheme(_ scheme: String) -> URL? {
    var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
    components?.scheme = scheme
    return components?.url
  }
}

// MARK: - ObjC compatibility on NSURL

extension NSURL {

  /// Returns `true` if the URL points to an external resource.
  @objc var isNYPLExternal: Bool {
    (self as URL).isNYPLExternal
  }

  /// Returns a new URL with the given scheme swapped in.
  @objc func urlBySwapping(forScheme scheme: String) -> NSURL? {
    (self as URL).swappingScheme(scheme) as NSURL?
  }
}
