import Foundation

/// Wrapper around NSXMLParser.
///
/// This class does not do any logging to Crashlytics.
///
/// This class does not intelligently support mixed-content elements: All children are always
/// TPPXML objects representing elements, and all text nodes within the parent are concatenated into a
/// single value. This is simple and convenient for parsing most data formats (e.g. OPDS), but it is not
/// suitable for handling markup (e.g. XHTML).
@objc class TPPXML: NSObject, XMLParserDelegate {

  @objc private(set) var attributes: NSDictionary = [:]
  @objc private(set) var name: String = ""
  @objc private(set) var namespaceURI: String = ""
  @objc weak private(set) var parent: TPPXML?
  @objc private(set) var qualifiedName: String = ""

  private var mutableChildren: [TPPXML] = []
  private var mutableValue: String = ""

  @objc var children: [TPPXML] {
    return mutableChildren
  }

  @objc var value: String {
    return mutableValue
  }

  // Private initializer for internal use
  private override init() {
    super.init()
  }

  @objc static func xml(withData data: Data?) -> TPPXML? {
    guard let data = data else { return nil }

    let document = TPPXML()

    // Mutable copy works around a bug with NSXMLParser that causes a crash in 64-bit simulators.
    let mutableData = NSMutableData(data: data) as Data

    let parser = XMLParser(data: mutableData)
    parser.delegate = document
    parser.shouldProcessNamespaces = true
    parser.parse()

    if parser.parserError != nil {
      return nil
    } else {
      guard let root = document.children.first else { return nil }
      root.parent = nil
      return root
    }
  }

  @objc func childrenWithName(_ name: String?) -> [TPPXML] {
    guard let name = name else { return [] }
    return children.filter { $0.name == name }
  }

  @objc func firstChild(withName name: String?) -> TPPXML? {
    return childrenWithName(name).first
  }

  // MARK: - XMLParserDelegate

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    let child = TPPXML()
    child.attributes = attributes as NSDictionary
    child.name = elementName
    child.namespaceURI = namespaceURI ?? ""
    child.parent = self
    child.qualifiedName = qualifiedName ?? ""

    mutableChildren.append(child)
    parser.delegate = child
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    parser.delegate = self.parent
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    mutableValue.append(string)
  }
}
