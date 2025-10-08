import Foundation

/// Service responsible for catalog sorting operations
class CatalogSortService {
  
  enum SortOption: CaseIterable {
    case authorAZ, authorZA, recentlyAddedAZ, recentlyAddedZA, titleAZ, titleZA
    
    var localizedString: String {
      switch self {
      case .authorAZ: return "Author (A-Z)"
      case .authorZA: return "Author (Z-A)"
      case .recentlyAddedAZ: return "Recently Added (A-Z)"
      case .recentlyAddedZA: return "Recently Added (Z-A)"
      case .titleAZ: return "Title (A-Z)"
      case .titleZA: return "Title (Z-A)"
      }
    }
    
    static func from(localizedString: String) -> SortOption? {
      return allCases.first { $0.localizedString == localizedString }
    }
  }
  
  /// Sort books in place according to the given sort option
  static func sort(books: inout [TPPBook], by sortOption: SortOption) {
    switch sortOption {
    case .authorAZ:
      books.sort { (($0.authors ?? "") + " " + $0.title) < (($1.authors ?? "") + " " + $1.title) }
    case .authorZA:
      books.sort { (($0.authors ?? "") + " " + $0.title) > (($1.authors ?? "") + " " + $1.title) }
    case .recentlyAddedAZ:
      books.sort { $0.updated < $1.updated }
    case .recentlyAddedZA:
      books.sort { $0.updated > $1.updated }
    case .titleAZ:
      books.sort { ($0.title + " " + ($0.authors ?? "")) < ($1.title + " " + ($1.authors ?? "")) }
    case .titleZA:
      books.sort { ($0.title + " " + ($0.authors ?? "")) > ($1.title + " " + ($1.authors ?? "")) }
    }
  }
  
  /// Returns a sorted copy of the books array
  static func sorted(books: [TPPBook], by sortOption: SortOption) -> [TPPBook] {
    var mutableBooks = books
    sort(books: &mutableBooks, by: sortOption)
    return mutableBooks
  }
}
