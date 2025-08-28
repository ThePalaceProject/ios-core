import SwiftUI

// MARK: - Keys & Utilities

private struct FacetKey {
  static func isAllTitle(_ title: String?) -> Bool {
    let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return t == "all" || t == "all formats" || t == "all collections" || t == "all distributors"
  }
  /// Canonical sheet key: "group|title|href"
  static func make(group: String, title: String, href: String) -> String {
    "\(group)|\(title)|\(href)"
  }
}

/// Immutable model we pass to the section view so it’s easy to test/reason about.
private struct FacetGroupModel: Identifiable {
  let id: String
  let name: String
  let items: [TPPCatalogFacet]

  var orderedItems: [TPPCatalogFacet] {
    items.sorted { lhs, rhs in
      let la = FacetKey.isAllTitle(lhs.title)
      let ra = FacetKey.isAllTitle(rhs.title)
      if la == ra { return (lhs.title ?? "") < (rhs.title ?? "") }
      return la && !ra
    }
  }
}

// MARK: - Public Sheet

struct CatalogFiltersSheetView: View {
  let facetGroups: [TPPCatalogFacetGroup]
  @Binding var selection: Set<String>
  let onApply: () -> Void
  let isApplying: Bool

  @State private var expanded: Set<String> = []
  private var groups: [FacetGroupModel] {
    facetGroups
      .filter { !$0.name.lowercased().contains("sort") }
      .map { g in
        FacetGroupModel(
          id: g.name,
          name: g.name,
          items: g.facets.compactMap { $0 as? TPPCatalogFacet }
        )
      }
  }

  var body: some View {
    NavigationView {
      VStack {
        List {
          ForEach(groups) { group in
            Section(header: FacetSectionHeader(
              title: group.name.capitalized,
              onClear: { clearGroup(group) },
              isExpanded: expanded.contains(group.id),
              toggleExpanded: { toggle(group.id) }
            )) {
              if expanded.contains(group.id) {
                ForEach(group.orderedItems, id: \.href) { facet in
                  FacetRowButton(
                    isSelected: selection.contains(key(for: group, facet: facet)),
                    title: facet.title ?? "",
                    onTap: { toggleSelection(in: group, facet: facet) }
                  )
                }
                .listRowSeparator(.hidden)
              }
            }
            .listRowSeparator(.hidden)
          }
          
          BottomApplyBar(isApplying: isApplying, onApply: onApply)
        }
        .listSectionSeparator(.hidden, edges: .all)
        .listRowSeparator(.hidden, edges: .all)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .environment(\.editMode, .constant(.inactive))
        .onAppear(perform: configureInitialSelection)
        
      }
    }
  }
}

// MARK: - Intent / Logic

private extension CatalogFiltersSheetView {
  func key(for group: FacetGroupModel, facet: TPPCatalogFacet) -> String {
    FacetKey.make(
      group: group.id,
      title: facet.title ?? "",
      href: facet.href?.absoluteString ?? ""
    )
  }

  func toggle(_ groupID: String) {
    if expanded.contains(groupID) { expanded.remove(groupID) } else { expanded.insert(groupID) }
  }

  func clearGroup(_ group: FacetGroupModel) {
    let groupKeys = Set(group.items.map { key(for: group, facet: $0) })
    selection.subtract(groupKeys)
    if let all = group.items.first(where: { FacetKey.isAllTitle($0.title) }) {
      selection.insert(key(for: group, facet: all))
    }
  }

  func toggleSelection(in group: FacetGroupModel, facet: TPPCatalogFacet) {
    let k = key(for: group, facet: facet)
    let groupKeys = Set(group.items.map { key(for: group, facet: $0) })

    if FacetKey.isAllTitle(facet.title) {
      selection.subtract(groupKeys)
      selection.insert(k)
      return
    }

    if let all = group.items.first(where: { FacetKey.isAllTitle($0.title) }) {
      selection.remove(key(for: group, facet: all))
    }

    if selection.contains(k) {
      selection.remove(k)
      let stillHasAny = selection.contains(where: { $0.hasPrefix("\(group.id)|") })
      if !stillHasAny, let all = group.items.first(where: { FacetKey.isAllTitle($0.title) }) {
        selection.insert(key(for: group, facet: all))
      }
    } else {
      selection.insert(k)
    }
  }

  func configureInitialSelection() {
    expanded = []

    if selection.isEmpty {
      let activeKeys = groups.flatMap { group in
        group.items.filter { $0.active }.map { key(for: group, facet: $0) }
      }
      if !activeKeys.isEmpty { selection = Set(activeKeys) }
    }

    for group in groups {
      let hasAnyInGroup = selection.contains { $0.hasPrefix("\(group.id)|") }
      if !hasAnyInGroup, let all = group.items.first(where: { FacetKey.isAllTitle($0.title) }) {
        selection.insert(key(for: group, facet: all))
      }
    }
  }
}

// MARK: - Subviews

private struct FacetSectionHeader: View {
  let title: String
  let onClear: () -> Void
  let isExpanded: Bool
  let toggleExpanded: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Text(title).font(.headline)
      Spacer()
      VStack {
        Button("Clear", action: onClear)
          .buttonStyle(.plain)
          .padding(.bottom, -5)
        Divider().background(.primary)
      }
      .frame(width: 50)

      Button(action: toggleExpanded) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .foregroundColor(.secondary)
          .monospaced()
      }
    }
    .listRowBackground(Color.clear)
    .buttonStyle(.plain)
  }
}

private struct FacetRowButton: View {
  let isSelected: Bool
  let title: String
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
          .foregroundColor(isSelected ? .accentColor : .secondary)
        Text(title)
          .palaceFont(size: 16)
        Spacer()
      }
    }
    .buttonStyle(.plain)
    .listRowBackground(Color.clear)
  }
}

private struct BottomApplyBar: View {
  let isApplying: Bool
  let onApply: () -> Void

  var body: some View {
    HStack {
      ZStack {
        Button(action: onApply) {
          Text("SHOW RESULTS").bold()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(buttonBackground)
        .foregroundColor(buttonForeground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .disabled(isApplying)
      if isApplying { ProgressView() }
      }

      Spacer()
      
    }
    .padding(.top, 40)
  }

  private var buttonBackground: Color {
    Color(UIColor { trait in trait.userInterfaceStyle == .dark ? .white : .black })
  }
  private var buttonForeground: Color {
    Color(UIColor { trait in trait.userInterfaceStyle == .dark ? .black : .white })
  }
}
