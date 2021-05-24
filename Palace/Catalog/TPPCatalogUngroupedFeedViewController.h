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
