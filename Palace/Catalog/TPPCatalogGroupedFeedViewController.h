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
