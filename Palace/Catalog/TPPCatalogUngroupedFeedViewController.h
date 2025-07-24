// ⚠️ DEPRECATED: This class is being replaced by SwiftUI CatalogBooksGridView and CatalogView
// in the Modern catalog architecture. New code should use the SwiftUI-based catalog system.
// This class will be removed in a future release.

@class TPPCatalogUngroupedFeed;
@class TPPRemoteViewController;

#import "TPPBookCellCollectionViewController.h"

@interface TPPCatalogUngroupedFeedViewController : TPPBookCellCollectionViewController

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;
- (id)initWithCoder:(NSCoder *)aDecoder NS_UNAVAILABLE;
- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil NS_UNAVAILABLE;

// |remoteViewController| is weakly referenced.
- (instancetype)initWithUngroupedFeed:(TPPCatalogUngroupedFeed *)feed
                 remoteViewController:(TPPRemoteViewController *)remoteViewController;

@end
