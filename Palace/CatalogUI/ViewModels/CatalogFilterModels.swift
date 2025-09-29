import Foundation

// MARK: - CatalogFilter

struct CatalogFilter: Identifiable, Hashable {
  let id: String
  let title: String
  let href: URL?
  let active: Bool
}

// MARK: - CatalogFilterGroup

struct CatalogFilterGroup: Identifiable, Hashable {
  let id: String
  let name: String
  let filters: [CatalogFilter]
}
