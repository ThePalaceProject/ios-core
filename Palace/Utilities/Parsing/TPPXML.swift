import Foundation

/// Swift port of TPPXML. A simple wrapper around XMLParser.
///
/// This class does not intelligently support mixed-content elements: All children are always
/// TPPXML objects representing elements, and all text nodes within the parent are concatenated
/// into a single value. This is simple and convenient for parsing most data formats (e.g. OPDS),
/// but it is not suitable for handling markup (e.g. XHTML).
@objcMembers
final class TPPXMLSwift: NSObject {

  let attributes: [String: String]
  private(set) var children: [TPPXMLSwift]
  let name: String
  let namespaceURI: String?
  weak private(set) var parent: TPPXMLSwift?
  let qualifiedName: String?
  private(set) var value: String

  private var mutableValue: NSMutableString?
  private var mutableChildren: NSMutableArray?

  // Internal initializer used during parsing
  private override init() {
    self.attributes = [:]
    self.children = []
    self.name = ""
    self.namespaceURI = nil
    self.parent = nil
    self.qualifiedName = nil
    self.value = ""
    super.init()
  }

  fileprivate init(
    attributes: [String: String],
    name: String,
    namespaceURI: String?,
    qualifiedName: String?,
    parent: TPPXMLSwift?
  ) {
    self.attributes = attributes
    self.children = []
    self.name = name
    self.namespaceURI = namespaceURI
    self.parent = parent
    self.qualifiedName = qualifiedName
    self.value = ""
    super.init()
  }

  /// Parse XML data and return the root element, or nil on failure.
  static func xml(with data: Data?) -> TPPXMLSwift? {
    guard let data = data else { return nil }

    let document = TPPXMLSwift()
    let parserDelegate = TPPXMLParserDelegate(root: document)

    // Mutable copy works around an NSXMLParser bug in 64-bit simulators
    let mutableData = NSMutableData(data: data)

    let parser = XMLParser(data: mutableData as Data)
    parser.delegate = parserDelegate
    parser.shouldProcessNamespaces = true
    parser.parse()

    if parser.parserError != nil {
      return nil
    }

    guard !document.children.isEmpty else { return nil }
    let root = document.children[0]
    root.parent = nil
    return root
  }

  /// Returns all direct children with the given local name.
  func children(withName name: String?) -> [TPPXMLSwift] {
    guard let name = name else { return [] }
    return children.filter { $0.name == name }
  }

  /// Returns the first direct child with the given local name, or nil.
  func firstChild(withName name: String?) -> TPPXMLSwift? {
    children(withName: name).first
  }

  // MARK: - Internal mutation (used by parser delegate)

  fileprivate func appendChild(_ child: TPPXMLSwift) {
    children.append(child)
  }

  fileprivate func appendValue(_ string: String) {
    value += string
  }
}

// MARK: - XMLParser Delegate

/// Separate delegate class to avoid exposing NSXMLParserDelegate on the public API.
private final class TPPXMLParserDelegate: NSObject, XMLParserDelegate {

  /// Stack of elements being parsed. The last element is the current context.
  private var stack: [TPPXMLSwift]

  init(root: TPPXMLSwift) {
    self.stack = [root]
    super.init()
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes attributeDict: [String: String]
  ) {
    let parent = stack.last!
    let child = TPPXMLSwift(
      attributes: attributeDict,
      name: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qualifiedName,
      parent: parent
    )
    parent.appendChild(child)
    stack.append(child)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    stack.removeLast()
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    stack.last?.appendValue(string)
  }
}
