import SwiftUI

// MARK: - FacetsSelectorView

struct FacetsSelectorView: View {
  let facetGroups: [CatalogFilterGroup]
  let onSelect: (CatalogFilter) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
        ForEach(facetGroups, id: \.id) { group in
          HStack(spacing: 8) {
            ForEach(group.filters, id: \.id) { facet in
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

// MARK: - EntryPointsSelectorView

struct EntryPointsSelectorView: View {
  let entryPoints: [CatalogFilter]
  let onSelect: (CatalogFilter) -> Void
  @State private var selectionIndex: Int = 0
  @State private var pendingIndex: Int = 0

  var body: some View {
    HStack {
      Picker("", selection: $selectionIndex) {
        ForEach(entryPoints.indices, id: \.self) { idx in
          Text(entryPoints[idx].title).tag(idx)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: .infinity)
    }
    .frame(maxWidth: 700)
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .onAppear {
      if let idx = entryPoints.firstIndex(where: { $0.active }) {
        selectionIndex = idx
        pendingIndex = idx
      } else {
        selectionIndex = min(selectionIndex, max(entryPoints.count - 1, 0))
        pendingIndex = selectionIndex
      }
    }
    .onChange(of: selectionIndex) { idx in
      guard entryPoints.indices.contains(idx) else {
        return
      }
      pendingIndex = idx
      // Debounce slight delay to avoid double reloads when tabs change
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        if pendingIndex == idx, entryPoints.indices.contains(idx) {
          onSelect(entryPoints[idx])
        }
      }
    }
    .onChange(of: entryPoints.count) { _ in
      if let idx = entryPoints.firstIndex(where: { $0.active }) {
        selectionIndex = idx
        pendingIndex = idx
      } else {
        selectionIndex = min(selectionIndex, max(entryPoints.count - 1, 0))
        pendingIndex = selectionIndex
      }
    }
  }
}

private extension NSObject {
  @objc var _uuid: String { String(ObjectIdentifier(self).hashValue) }
}
