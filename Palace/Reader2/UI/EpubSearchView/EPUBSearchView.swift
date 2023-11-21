//
//  EPUBSearchView.swift
//  Palace
//
//  Created by Maurice Carrier on 10/9/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI
import Combine
import R2Shared
import R2Navigator

struct EPUBSearchView: View {
  @ObservedObject var viewModel: EPUBSearchViewModel
  @State private var searchQuery: String = ""
  @State private var debounceSearch: AnyCancellable?

  @FocusState private var isSearchFieldFocused: Bool
  
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
  
  var body: some View {
    VStack {
      searchBar
      listView
    }
    .onChange(of: searchQuery, perform: search)
    .padding()
    .ignoresSafeArea(.keyboard)
  }

  @ViewBuilder private var listView: some View {
    ZStack {
      List {
        ForEach(viewModel.groupedResults, id: \.title) { section in
          Section(header: sectionHeaderView(title: section.title)) {
            ForEach(section.locators, id: \.self) { locator in
              rowView(locator)
                .onAppear(perform: {
                  if shouldFetchMoreResults(for: locator) {
                    viewModel.fetchNextBatch()
                  }
                })
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
        }
        Spacer()
      }
    }
  }

  private func shouldFetchMoreResults(for locator: Locator) -> Bool {
    if let lastSection = viewModel.groupedResults.last,
       let lastLocator = lastSection.locators.last {
      return locator.href == lastLocator.href
    }
    return false
  }

  private func sectionHeaderView(title: String) -> some View {
    Text(title.uppercased(  ))
      .padding(.leading)
      .font(.largeTitle)
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
      highlight.font = .system(size: 16, weight: .medium)
      
      combinedText.append(highlight)
      combinedText.append(AttributedString(text.after ?? ""))
      
      return Text(combinedText)
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
        viewModel.search(with: value)
      }
  }
}

