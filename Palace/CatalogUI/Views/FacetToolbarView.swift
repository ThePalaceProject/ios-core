import SwiftUI

struct FacetToolbarView: View {
  let title: String?
  let showFilter: Bool
  let onSort: () -> Void
  let onFilter: () -> Void
  let currentSortTitle: String
  var appliedFiltersCount: Int = 0

  var body: some View {
    HStack(spacing: 10) {
      if let title {
        Text(title)
          .palaceFont(size: 18)
          .bold()
      }
      Spacer()
      Button(action: onSort) {
        HStack(spacing: 2) {
          ImageProviders.MyBooksView.sort
          Text(currentSortTitle)
        }
        .palaceFont(size: 14)
      }
      .buttonStyle(.plain)
      if showFilter {
        Button(action: onFilter) {
          HStack(spacing: 3) {
            ImageProviders.MyBooksView.filter
            if appliedFiltersCount > 0 {
              Text("\(Strings.Catalog.filter) (\(appliedFiltersCount))")
            } else {
              Text(Strings.Catalog.filter)
            }
          }
          .palaceFont(size: 14)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
