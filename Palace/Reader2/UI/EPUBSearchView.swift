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


final class SearchViewModel: ObservableObject {
  enum State {
    case empty
    case starting(R2Shared.Cancellable?)
    case idle(SearchIterator)
    case loadingNext(SearchIterator, R2Shared.Cancellable?)
    case end
    case failure(LocalizedError)
  }
  
  @Published private(set) var state: State = .empty
  @Published private(set) var results: [Locator] = []
  
  private var publication: Publication
  
  init(publication: Publication) {
    self.publication = publication
  }

  func search(with query: String) {
    cancelSearch()
    
    let cancellable = publication._search(query: query) { result in
      switch result {
      case .success(let iterator):
        self.state = .idle(iterator)
        self.fetchAllLocations(iterator: iterator)
        
      case .failure(let error):
        self.state = .failure(error)
      }
    }
    
    state = .starting(cancellable)
  }
  
  func fetchAllLocations(iterator: SearchIterator) {
    state = .loadingNext(iterator, nil)
    
    let cancellable = iterator.next { result in
      switch result {
      case .success(let collection):
        if let collection = collection {
          self.results.append(contentsOf: collection.locators)
          self.fetchAllLocations(iterator: iterator)
        } else {
          self.state = .end
        }
        
      case .failure(let error):
        self.state = .failure(error)
      }
    }
    
    state = .loadingNext(iterator, cancellable)
  }
  /// Cancels any on-going search and clears the results.
  func cancelSearch() {
    switch state {
    case .starting(let cancellable):
      cancellable?.cancel()
    case .idle(let iterator):
      iterator.close()
    case .loadingNext(let iterator, let cancellable):
      cancellable?.cancel()
      iterator.close()
    default:
      break
    }
    
    results.removeAll()
    state = .empty
  }
}

struct EPUBSearchView: View {
  @ObservedObject var viewModel: SearchViewModel
  @State private var searchQuery: String = ""
  
  var body: some View {
    VStack {
      searchBar
      listView
    }
    .onChange(of: searchQuery, perform: { newValue in
      viewModel.search(with: newValue)
    })
    .padding()
  }
  
  @ViewBuilder private var searchBar: some View {
    HStack {
      TextField("\(Strings.Generic.search)...", text: $searchQuery)
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
  }

  @ViewBuilder private var listView: some View {
    ZStack {
      List {
        ForEach(groupedByChapterName(viewModel.results), id: \.key) { key, locators in
          Section(header: sectionHeaderView(title: key)) {
            ForEach(locators, id: \.href) { locator in
              rowView(locator)
            }
          }
        }
      }
      .listStyle(PlainListStyle())
      
      if viewModel.results.isEmpty && searchQuery != "" {
        Text(Strings.TPPEPUBViewController.emptySearchView)
      }
    }
  }
  
  private func groupedByChapterName(_ results: [Locator]) -> [(key: String, value: [Locator])] {
    let uniqueTitles = Array(Set(results.compactMap { $0.title })).sorted { title1, title2 in
      results.firstIndex(where: { $0.title == title1 })! < results.firstIndex(where: { $0.title == title2 })!
    }
    
    return uniqueTitles.compactMap { title -> (key: String, value: [Locator])? in
      if let items = results.filter({ $0.title == title }) as [Locator]?, !items.isEmpty {
        return (key: title, value: items)
      }
      return nil
    }
  }

  private func sectionHeaderView(title: String) -> some View {
    Text(title.uppercased())
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
    return VStack {
      Text(text.before ?? "") +
      Text(text.highlight ?? "").foregroundColor(Color.orange).fontWeight(.medium) +
      Text(text.after ?? "")
    }
    .padding(5)
  }
}
