// ⚠️ DEPRECATED: This class is being replaced by SwiftUI CatalogLanesView and CatalogView
// in the Modern catalog architecture. New code should use the SwiftUI-based catalog system.
// This class will be removed in a future release.

@class TPPCatalogGroupedFeed;
@class TPPRemoteViewController;

@interface TPPCatalogGroupedFeedViewController : UIViewController

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;
- (id)initWithCoder:(NSCoder *)aDecoder NS_UNAVAILABLE;
- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil NS_UNAVAILABLE;

- (instancetype)initWithGroupedFeed:(TPPCatalogGroupedFeed *const)feed
               remoteViewController:(TPPRemoteViewController *const)remoteViewController;
@end
