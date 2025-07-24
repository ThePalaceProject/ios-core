# Palace Catalog Modernization Migration Guide

## Overview

The Palace catalog system has been completely modernized, moving from Objective-C/UIKit to Swift/SwiftUI with a clean MVVM architecture. This guide helps developers transition from the legacy system to the new modern implementation.

## Architecture Changes

### Legacy Architecture (Deprecated)
- **Language**: Objective-C + some Swift
- **UI Framework**: UIKit
- **Architecture**: Mixed MVC/Delegate patterns
- **Networking**: Callback-based with `TPPSession`
- **Data Flow**: Manual state management

### Modern Architecture (New)
- **Language**: Swift
- **UI Framework**: SwiftUI
- **Architecture**: MVVM with Combine
- **Networking**: Async/await with `NetworkService`
- **Data Flow**: Reactive with `@Published` properties

## Key Components Mapping

| Legacy Component | Modern Replacement | Notes |
|------------------|-------------------|-------|
| `TPPCatalogNavigationController` | `ModernCatalogNavigationController` | SwiftUI hosting controller |
| `TPPCatalogFeedViewController` | `CatalogView` | Main SwiftUI view |
| `TPPCatalogGroupedFeedViewController` | `CatalogLanesView` | Horizontal lanes with books |
| `TPPCatalogUngroupedFeedViewController` | `CatalogBooksGridView` | Grid layout for books |
| `TPPCatalogSearchViewController` | `SearchResultsView` | Integrated search experience |
| `TPPCatalogGroupedFeed` | `CatalogFeed` | Modern Swift struct |
| `TPPCatalogUngroupedFeed` | `CatalogFeed` | Unified model |
| `TPPOpenSearchDescription` | `OpenSearchDescription` | Codable struct |

## Migration Steps

### 1. Update Navigation Controller

**Before (Legacy):**
```objc
TPPCatalogNavigationController *catalogNav = [[TPPCatalogNavigationController alloc] init];
```

**After (Modern):**
```swift
let catalogNav = ModernCatalogNavigationController()
```

### 2. Replace Feed Loading

**Before (Legacy):**
```objc
[TPPCatalogUngroupedFeed withURL:url 
                 useTokenIfAvailable:YES 
                         handler:^(TPPCatalogUngroupedFeed *feed) {
    // Handle feed
}];
```

**After (Modern):**
```swift
Task {
    do {
        let feed = try await CatalogService.shared.fetchCatalogFeed(from: url)
        // Handle feed
    } catch {
        // Handle error
    }
}
```

### 3. Update Search Implementation

**Before (Legacy):**
```objc
TPPCatalogSearchViewController *searchVC = 
    [[TPPCatalogSearchViewController alloc] initWithOpenSearchDescription:description];
[self.navigationController pushViewController:searchVC animated:YES];
```

**After (Modern):**
```swift
// Search is now integrated into CatalogView
// Use the search bar in the navigation
viewModel.searchCatalog(query: searchText)
```

### 4. Handle State Management

**Before (Legacy):**
```objc
// Manual delegate callbacks
- (void)catalogUngroupedFeed:(TPPCatalogUngroupedFeed *)feed 
              didUpdateBooks:(NSArray *)books {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}
```

**After (Modern):**
```swift
// Reactive updates with Combine
@Published var books: [TPPBook] = []

// UI automatically updates when books change
```

## New Features

### 1. Async/Await Networking
```swift
// Clean async code
let feed = try await networkService.fetchCatalogFeed(from: url)
```

### 2. Reactive UI Updates
```swift
// SwiftUI automatically updates when @Published properties change
@Published var isLoading = false
@Published var currentFeed: CatalogFeed?
```

### 3. Comprehensive Caching
```swift
// Automatic caching with expiration
let cachedFeed = await cacheService.getCachedFeed(for: url)
```

### 4. Error Handling
```swift
// Structured error handling
enum CatalogError: LocalizedError {
    case networkError(String)
    case parsingError(String)
    // ...
}
```

## Performance Improvements

1. **Lazy Loading**: SwiftUI's `LazyVStack` and `LazyVGrid` for better performance
2. **Caching**: Intelligent feed caching with expiration
3. **Prefetching**: Automatic prefetching of next pages
4. **Memory Management**: Better memory usage with Swift value types

## Backward Compatibility

The legacy system remains functional during the transition period:

1. **Gradual Migration**: Both systems can coexist
2. **Feature Flags**: Use `ModernCatalogNavigationController` selectively
3. **API Compatibility**: Legacy methods marked as deprecated but still functional

## Testing Strategy

### Unit Tests
```swift
// Test ViewModels in isolation
func testCatalogLoading() async {
    let viewModel = CatalogViewModel()
    await viewModel.loadCatalog(from: testURL)
    XCTAssertNotNil(viewModel.currentFeed)
}
```

### SwiftUI Previews
```swift
struct CatalogView_Previews: PreviewProvider {
    static var previews: some View {
        CatalogView()
    }
}
```

## Common Issues & Solutions

### 1. Navigation Integration
**Issue**: SwiftUI navigation not working with UIKit app structure

**Solution**: Use `ModernCatalogNavigationController` as a bridge

### 2. State Synchronization
**Issue**: Data not updating between legacy and modern components

**Solution**: Use shared singletons (`CatalogService.shared`) and notifications

### 3. Image Loading
**Issue**: Book cover images not loading in SwiftUI

**Solution**: Use `AsyncImage` with proper placeholder handling

## Deprecation Timeline

- **Phase 1**: Modern system introduced, legacy marked deprecated ✅
- **Phase 2**: Migration guide published, developers transition (Current)
- **Phase 3**: Legacy system warnings increased
- **Phase 4**: Legacy system removed

## Resources

- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui)
- [Combine Framework](https://developer.apple.com/documentation/combine)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)

## Support

For questions about migration or issues with the new system:
1. Check this migration guide
2. Review the modern implementation examples
3. Test with the provided preview data
4. Reach out to the development team for complex migration scenarios 