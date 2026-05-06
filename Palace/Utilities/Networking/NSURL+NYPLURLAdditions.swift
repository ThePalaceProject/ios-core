import Foundation

extension NSURL {

  @objc var isNYPLExternal: Bool {
    if (self as URL).isFileURL { return false }
    if scheme == "about" { return false }
    if host == "127.0.0.1" || host == "::1" || host == "localhost" { return false }
    return true
  }

  @objc func urlBySwapping(forScheme scheme: String) -> NSURL? {
    guard var components = URLComponents(url: self as URL, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = scheme
    return components.url as NSURL?
  }
}
