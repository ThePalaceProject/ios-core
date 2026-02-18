//
//  EPUBSearchView.swift
//  Palace
//
//  Created by Maurice Carrier on 10/9/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine
import ReadiumShared
import ReadiumNavigator
import PalaceUIKit

struct EPUBSearchView: View {
  @ObservedObject var viewModel: EPUBSearchViewModel
  @State private var searchQuery: String = ""
  @State private var debounceSearch: AnyCancellable?

  @FocusState private var isSearchFieldFocused: Bool
  @Environment(\.presentationMode) var presentationMode

  var body: some View {
    VStack {
      HStack {
        Button(action: {
          presentationMode.wrappedValue.dismiss()
        }) {
          Image(systemName: "chevron.left")
            .foregroundColor(.primary)
            .padding(.trailing, 8)
        }
        .accessibilityLabel(Strings.Generic.goBack)
        Text(Strings.Generic.search)
          .font(.headline)
        Spacer()
      }
      .padding()

      searchBar
      listView
    }
    .onChange(of: searchQuery, perform: search)
    .padding()
    .ignoresSafeArea(.keyboard)
  }

  @ViewBuilder private var searchBar: some View {
    HStack {
      TextField("\(Strings.Generic.search)...", text: $searchQuery)
        .focused($isSearchFieldFocused)
      Button(action: {
        searchQuery = ""
        viewModel.cancelSearch()
      }) {
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(Color.gray)
          .padding(.leading, 5)
      }
      .accessibilityLabel(Strings.Generic.clearSearch)
    }
    .padding()
    .background(Color(.secondarySystemBackground))
    .cornerRadius(8)
    .padding(.bottom)
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        isSearchFieldFocused = true
      }
    }
  }

  @ViewBuilder private var listView: some View {
    ZStack {
      List {
        ForEach(viewModel.sections, id: \.id) { section in
          if section.title.isEmpty {
            Section {
              sectionContent(section)
            }
          } else {
            Section(header: sectionHeaderView(title: section.title)) {
              sectionContent(section)
            }
          }
        }
      }
      .listStyle(.plain)

      VStack {
        Spacer()
        if viewModel.state.isLoadingState {
          ProgressView()
        } else if viewModel.results.isEmpty && searchQuery != "" {
          Text(Strings.TPPEPUBViewController.emptySearchView)
            .palaceFont(.body)
        }
        Spacer()
      }
    }
  }

  @ViewBuilder private func sectionContent(_ section: SearchViewSection) -> some View {
    ForEach(section.locators, id: \.self) { locator in
      rowView(locator)
        .onAppear(perform: {
          Task {
            if shouldFetchMoreResults(for: locator) {
              await viewModel.fetchNextBatch()
            }
          }
        })
    }
  }

  private func shouldFetchMoreResults(for locator: Locator) -> Bool {
    if let lastSection = viewModel.sections.last,
       let lastLocator = lastSection.locators.last {
      return locator.href.isEquivalentTo(lastLocator.href)
    }
    return false
  }

  private func sectionHeaderView(title: String) -> some View {
    Text(title.uppercased())
      .palaceFont(.headline)
      .foregroundColor(.black.opacity(0.8))
      .textCase(.none)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var footer: some View {
    switch viewModel.state {
    case .failure(let error):
      Text("\(Strings.Generic.error.capitalized) \(error.localizedDescription)")
    default:
      EmptyView()
    }
  }

  private func rowView(_ locator: Locator) -> some View {
    let text = locator.text.sanitized()

    if #available(iOS 15.0, *) {
      var combinedText = AttributedString(text.before ?? "")

      var highlight = AttributedString(text.highlight ?? "")
      highlight.backgroundColor = .red.opacity(0.3)
      highlight.font = .semiBoldPalaceFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize)

      combinedText.append(highlight)
      combinedText.append(AttributedString(text.after ?? ""))

      return Text(combinedText)
        .palaceFont(.body)
        .onTapGesture {
          viewModel.userSelected(locator)
        }
        .padding(5)
    } else {
      return VStack {
        Text(text.before ?? "") +
        Text(text.highlight ?? "").foregroundColor(Color.red).fontWeight(.medium) +
        Text(text.after ?? "")
      }
      .palaceFont(.body)
      .onTapGesture {
        viewModel.userSelected(locator)
      }
      .padding(5)
    }
  }

  private func search(newValue: String) {
    debounceSearch?.cancel()
    debounceSearch = Just(newValue)
      .delay(for: .seconds(0.5), scheduler: RunLoop.main)
      .sink { value in
        Task {
          await viewModel.search(with: value)
        }
      }
  }
}
