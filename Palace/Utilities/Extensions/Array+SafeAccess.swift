import Foundation

extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }

  func safePrefix(_ maxLength: Int) -> ArraySlice<Element> {
    prefix(Swift.min(maxLength, count))
  }

  func first(default defaultValue: Element) -> Element {
    first ?? defaultValue
  }
}

extension Collection {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
