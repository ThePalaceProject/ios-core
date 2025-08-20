import SwiftUI

struct FacetsSelectorView: View {
  let facetGroups: [TPPCatalogFacetGroup]
  let onSelect: (TPPCatalogFacet) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(facetGroups, id: \._uuid) { group in
          HStack(spacing: 8) {
            ForEach(group.facets.compactMap { $0 as? TPPCatalogFacet }, id: \._uuid) { facet in
              Button(action: { onSelect(facet) }) {
                Text(facet.title)
                  .padding(.vertical, 8)
                  .padding(.horizontal, 12)
                  .background(facet.active ? Color.gray.opacity(0.3) : Color.clear)
                  .clipShape(Capsule())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }
}

private extension NSObject {
  @objc var _uuid: String { String(ObjectIdentifier(self).hashValue) }
}


