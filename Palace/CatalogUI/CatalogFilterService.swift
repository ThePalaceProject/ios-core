import Foundation

/// Service responsible for catalog filter operations and state management
class CatalogFilterService {
  
  // MARK: - Filter Key Management
  
  struct ParsedKey {
    let group: String
    let title: String
    let hrefString: String
    
    var isDefaultTitle: Bool {
      let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return t == "all" || t == "all formats" || t == "all collections" || t == "all distributors"
    }
  }
  
  /// Canonical key is "group|title|href"
  static func makeKey(group: String, title: String, hrefString: String) -> String {
    "\(group)|\(title)|\(hrefString)"
  }
  
  /// Group-title-only key
  static func makeGroupTitleKey(group: String, title: String) -> String {
    "\(group)|\(title)"
  }
  
  static func parseKey(_ key: String) -> ParsedKey? {
    let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3 else { return nil }
    return ParsedKey(group: parts[0], title: parts[1], hrefString: parts[2])
  }
  
  static func normalizeTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
  
  // MARK: - Filter Selection Management
  
  /// Map stored group|title selections to current facet keys with up-to-date hrefs
  static func keysForCurrentFacets(fromGroupTitleKeys keys: Set<String>, facetGroups: [CatalogFilterGroup]) -> Set<String> {
    var out: Set<String> = []
    let wanted: [String: Set<String>] = Dictionary(grouping: keys.compactMap { key -> (String, String)? in
      let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 2 else { return nil }
      return (parts[0], parts[1])
    }) { $0.0 }.mapValues { Set($0.map { normalizeTitle($0.1) }) }
    
    for group in facetGroups where !group.name.lowercased().contains("sort") {
      let titles = wanted[group.name] ?? []
      let facets = group.filters
      for facet in facets {
        let title = facet.title
        if titles.contains(normalizeTitle(title)) {
          let href = facet.href?.absoluteString ?? ""
          out.insert(makeKey(group: group.name, title: title, hrefString: href))
        }
      }
    }
    return out
  }
  
  /// Extract active facet keys from the current groups
  static func selectionKeysFromActiveFacets(facetGroups: [CatalogFilterGroup], includeDefaults: Bool) -> Set<String> {
    var out: [String] = []
    for group in facetGroups {
      if group.name.lowercased().contains("sort") { continue }
      let facets = group.filters.filter { $0.active }
      for facet in facets {
        let rawTitle = facet.title
        let parsed = ParsedKey(group: group.name, title: rawTitle, hrefString: facet.href?.absoluteString ?? "")
        if includeDefaults || !parsed.isDefaultTitle {
          out.append(makeKey(group: parsed.group, title: rawTitle, hrefString: parsed.hrefString))
        }
      }
    }
    return Set(out)
  }
  
  /// Reconstruct pending selections from applied selections using current facets
  static func reconstructSelectionsFromCurrentFacets(appliedSelections: Set<String>, facetGroups: [CatalogFilterGroup]) -> Set<String> {
    var reconstructed: Set<String> = []
    
    for appliedSelection in appliedSelections {
      let parts = appliedSelection.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 2 else { continue }
      
      let groupName = parts[0]
      let title = parts[1]
      
      // Find this filter in the fresh facet groups
      for group in facetGroups where group.name == groupName {
        for filter in group.filters where filter.title == title {
          let key = makeKey(group: group.name, title: filter.title, hrefString: filter.href?.absoluteString ?? "")
          reconstructed.insert(key)
          break
        }
      }
    }
    
    return reconstructed
  }
  
  /// The hrefs of **currently active** facets
  static func activeFacetHrefs(facetGroups: [CatalogFilterGroup], includeDefaults: Bool) -> [URL] {
    facetGroups
      .filter { !$0.name.lowercased().contains("sort") }
      .flatMap { group in
        group.filters
          .filter { $0.active }
          .compactMap { facet -> (String, URL)? in
            let title = facet.title
            let url = facet.href
            guard let url else { return nil }
            let parsed = ParsedKey(group: group.name, title: title, hrefString: url.absoluteString)
            return (includeDefaults || !parsed.isDefaultTitle) ? (title, url) : nil
          }
      }
      .map { $0.1 }
  }
  
  static func activeFiltersCount(appliedSelections: Set<String>) -> Int {
    appliedSelections.filter { groupTitleKey in
      let parts = groupTitleKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count >= 2 else { return false }
      let title = parts[1]
      let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let isDefaultTitle = t == "all" || t == "all formats" || t == "all collections" || t == "all distributors"
      return !isDefaultTitle
    }.count
  }
  
  // MARK: - Filter Priority & Ordering
  
  /// Gets priority for group ordering (lower number = higher priority)
  static func getGroupPriority(_ groupName: String) -> Int {
    let name = groupName.lowercased()
    if name.contains("collection") || name.contains("library") { return 1 }
    if name.contains("distributor") { return 2 }
    if name.contains("format") || name.contains("media") { return 3 }
    if name.contains("availability") || name.contains("available") { return 4 }
    if name.contains("language") || name.contains("lang") { return 5 }
    if name.contains("subject") || name.contains("genre") { return 6 }
    return 10
  }
  
  /// Finds the group name for a facet URL by matching it against current facet groups
  static func findFacetGroupName(for url: URL, in facetGroups: [CatalogFilterGroup]) -> String? {
    for group in facetGroups {
      for filter in group.filters {
        if filter.href?.absoluteString == url.absoluteString {
          return group.name
        }
      }
    }
    return nil
  }
  
  /// Categorizes a facet URL when no group is found
  static func categorizeFacetURL(_ url: URL) -> String {
    let urlString = url.absoluteString.lowercased()
    
    if urlString.contains("collection") || urlString.contains("library") {
      return "Collection"
    } else if urlString.contains("format") || urlString.contains("media") {
      return "Format"
    } else if urlString.contains("availability") || urlString.contains("available") {
      return "Availability"
    } else if urlString.contains("language") || urlString.contains("lang") {
      return "Language"
    } else if urlString.contains("subject") || urlString.contains("genre") {
      return "Subject"
    } else {
      return "Other"
    }
  }
  
  /// Find a specific filter in the current facet groups
  static func findFilterInCurrentFacets(_ filter: ParsedKey, in currentFacetGroups: [CatalogFilterGroup]) -> URL? {
    for group in currentFacetGroups {
      if group.name.lowercased() == filter.group.lowercased() {
        for facet in group.filters {
          if facet.title.lowercased() == filter.title.lowercased() {
            return facet.href
          }
        }
      }
    }
    return nil
  }
  
  /// Prioritizes selected filters for sequential application
  static func prioritizeSelectedFilters(_ facetURLs: [URL], currentFacetGroups: [CatalogFilterGroup]) -> [URL] {
    var filtersByGroup: [String: [URL]] = [:]
    
    for url in facetURLs {
      if let groupName = findFacetGroupName(for: url, in: currentFacetGroups) {
        filtersByGroup[groupName, default: []].append(url)
      } else {
        let category = categorizeFacetURL(url)
        filtersByGroup[category, default: []].append(url)
      }
    }
    
    let sortedGroups = filtersByGroup.sorted { (group1, group2) in
      let priority1 = getGroupPriority(group1.key)
      let priority2 = getGroupPriority(group2.key)
      return priority1 < priority2
    }
    
    return sortedGroups.compactMap { $0.value.first }
  }
}
