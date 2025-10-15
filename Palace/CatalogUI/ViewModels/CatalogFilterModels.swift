import Foundation

struct CatalogFilter: Identifiable, Hashable {
  let id: String
  let title: String
  let href: URL?
  let active: Bool
}

struct CatalogFilterGroup: Identifiable, Hashable {
  let id: String
  let name: String
  let filters: [CatalogFilter]
}
