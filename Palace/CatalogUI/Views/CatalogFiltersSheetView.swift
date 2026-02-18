import SwiftUI

// MARK: - Keys & Utilities

private struct FacetKey {
  static func isAllTitle(_ title: String?) -> Bool {
    let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return t == "all" || t == "all formats" || t == "all collections" || t == "all distributors"
  }
  static func make(group: String, title: String, href: String) -> String {
    "\(group)|\(title)|\(href)"
  }
}

private struct FacetGroupModel: Identifiable {
  let id: String
  let name: String
  let items: [CatalogFilter]
  
  var orderedItems: [CatalogFilter] {
    items.sorted { lhs, rhs in
      let la = FacetKey.isAllTitle(lhs.title)
      let ra = FacetKey.isAllTitle(rhs.title)
      if la == ra { return lhs.title < rhs.title }
      return la && !ra
    }
  }
}

// MARK: - Public Sheet

struct CatalogFiltersSheetView: View {
  let facetGroups: [CatalogFilterGroup]
  @Binding var selection: Set<String>
  let onApply: () -> Void
  let onCancel: () -> Void
  let isApplying: Bool
  
  @State private var expanded: Set<String> = []
  @State private var tempSelection: Set<String> = []
  
  private var groups: [FacetGroupModel] {
    facetGroups
      .filter { !$0.name.lowercased().contains("sort") }
      .map { g in
        FacetGroupModel(
          id: g.id,
          name: g.name,
          items: g.filters
        )
      }
  }
  
  var body: some View {
    NavigationView {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(groups) { group in
            VStack(spacing: 0) {
              FacetSectionHeader(
                title: group.name.capitalized,
                subtitle: selectedFilterSubtitle(for: group),
                onClear: { clearGroup(group) },
                isExpanded: expanded.contains(group.id),
                toggleExpanded: { toggle(group.id) },
                shouldShowClear: shouldShowClearButton(for: group)
              )
              .padding(.horizontal)
              .padding(.vertical, 12)
              .background(Color(UIColor.systemBackground))
              
              if expanded.contains(group.id) {
                ForEach(group.orderedItems, id: \.id) { facet in
                  FacetRowButton(
                    isSelected: tempSelection.contains(key(for: group, facet: facet)),
                    title: facet.title,
                    onTap: { toggleTempSelection(in: group, facet: facet) }
                  )
                  .padding(.horizontal)
                }
                .background(Color.clear)
              }
            }
          }
        }
        .padding(.top)
        
        ResultsButton(isApplying: isApplying, onApply: {
          selection = tempSelection
          onApply()
        }, onCancel: onCancel)
          .padding(.horizontal)
          .padding(.vertical, 12)
          .background(Color(UIColor.systemBackground).ignoresSafeArea())
        Spacer()
      }
      .background(Color(UIColor.systemBackground))
      .task { configureInitialSelection() }
    }
  }
}

// MARK: - Intent / Logic

private extension CatalogFiltersSheetView {
  func key(for group: FacetGroupModel, facet: CatalogFilter) -> String {
    FacetKey.make(
      group: group.id,
      title: facet.title,
      href: facet.href?.absoluteString ?? ""
    )
  }
  
  func toggle(_ groupID: String) {
    if expanded.contains(groupID) { expanded.remove(groupID) } else { expanded.insert(groupID) }
  }
  
  func clearGroup(_ group: FacetGroupModel) {
    let groupKeys = Set(group.items.map { key(for: group, facet: $0) })
    tempSelection.subtract(groupKeys)
    
    if let all = group.items.first(where: { FacetKey.isAllTitle($0.title) }) {
      tempSelection.insert(key(for: group, facet: all))
    } else if let firstItem = group.items.first {
      tempSelection.insert(key(for: group, facet: firstItem))
    }
  }
  
  func toggleTempSelection(in group: FacetGroupModel, facet: CatalogFilter) {
    let k = key(for: group, facet: facet)
    let groupKeys = Set(group.items.map { key(for: group, facet: $0) })
    
    tempSelection.subtract(groupKeys)
    tempSelection.insert(k)
  }
  
  func configureInitialSelection() {
    expanded = []
    tempSelection = selection
    
    for group in groups {
      let groupKeys = Set(group.items.map { key(for: group, facet: $0) })
      let currentSelections = tempSelection.intersection(groupKeys)
      
      if currentSelections.isEmpty {
        if let all = group.items.first(where: { FacetKey.isAllTitle($0.title) }) {
          tempSelection.insert(key(for: group, facet: all))
        } else if let firstItem = group.items.first {
          tempSelection.insert(key(for: group, facet: firstItem))
        }
      } else if currentSelections.count > 1 {
        tempSelection.subtract(groupKeys)
        if let firstSelection = currentSelections.first {
          tempSelection.insert(firstSelection)
        }
      }
    }
  }
  
  func shouldShowClearButton(for group: FacetGroupModel) -> Bool {
    let groupKeys = Set(group.items.map { key(for: group, facet: $0) })
    let currentSelections = tempSelection.intersection(groupKeys)
    
    // If nothing selected or multiple selected, show clear
    if currentSelections.isEmpty || currentSelections.count > 1 {
      return true
    }
    
    // If single selection, check if it's "All"
    guard let selectedKey = currentSelections.first else {
      return true
    }
    
    // Find the selected facet
    let selectedFacet = group.items.first { facet in
      key(for: group, facet: facet) == selectedKey
    }
    
    // Hide clear button if "All" is selected
    return !FacetKey.isAllTitle(selectedFacet?.title)
  }
  
  func selectedFilterSubtitle(for group: FacetGroupModel) -> String? {
    let groupKeys = Set(group.items.map { key(for: group, facet: $0) })
    let currentSelections = tempSelection.intersection(groupKeys)
    
    // Only show subtitle for single selection that's not "All"
    guard currentSelections.count == 1,
          let selectedKey = currentSelections.first else {
      return nil
    }
    
    // Find the selected facet
    let selectedFacet = group.items.first { facet in
      key(for: group, facet: facet) == selectedKey
    }
    
    // Return title if it's not "All"
    guard let facet = selectedFacet, !FacetKey.isAllTitle(facet.title) else {
      return nil
    }
    
    return facet.title
  }
}

// MARK: - Subviews

private struct FacetSectionHeader: View {
  let title: String
  let subtitle: String?
  let onClear: () -> Void
  let isExpanded: Bool
  let toggleExpanded: () -> Void
  let shouldShowClear: Bool
  
  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline).foregroundColor(.primary)
        if let subtitle = subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
      }
      Spacer()
      if shouldShowClear {
        VStack {
          Button("Clear", action: onClear)
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundColor(.primary)
            .padding(.bottom, -5)
        }
        .frame(width: 50)
      }
      
      Button(action: toggleExpanded) {
        Image(systemName: "chevron.right")
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .animation(.easeInOut(duration: 0.2), value: isExpanded)
          .foregroundColor(.primary)
      }
      .frame(width: 24, alignment: .center)
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? Strings.Generic.collapseSection : Strings.Generic.expandSection)
    }
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
          .foregroundColor(.primary)
        Text(title)
          .palaceFont(size: 16)
          .foregroundColor(.primary)
        Spacer()
      }
    }
    .buttonStyle(.plain)
    .padding(.vertical, 10)
    .background(Color.clear)
  }
}

private struct ResultsButton: View {
  let isApplying: Bool
  let onApply: () -> Void
  let onCancel: () -> Void
  
  var body: some View {
    HStack(spacing: 12) {
      Button(action: onCancel) {
        Text("CANCEL")
          .bold()
          .padding(.vertical, 12)
          .padding(.horizontal, 20)
          .background(Color.clear)
          .foregroundColor(.primary)
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.primary, lineWidth: 1)
          )
      }
      .disabled(isApplying)
      
      Button(action: onApply) {
        HStack(spacing: 8) {
          if isApplying {
            ProgressView()
              .progressViewStyle(CircularProgressViewStyle(tint: buttonForeground))
              .scaleEffect(0.8)
          }
          
          Text(isApplying ? "APPLYING..." : "APPLY FILTERS")
            .bold()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(isApplying ? buttonBackground.opacity(0.7) : buttonBackground)
        .foregroundColor(buttonForeground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      .disabled(isApplying)
      
      Spacer()
    }
  }
  
  private var buttonBackground: Color {
    Color(UIColor { trait in trait.userInterfaceStyle == .dark ? .white : .black })
  }
  private var buttonForeground: Color {
    Color(UIColor { trait in trait.userInterfaceStyle == .dark ? .black : .white })
  }
}

