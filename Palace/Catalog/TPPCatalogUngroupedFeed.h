@class TPPCatalogUngroupedFeed;
@class TPPOPDSFeed;
@class TPPCatalogFacet;

@protocol TPPCatalogUngroupedFeedDelegate

// Called only when existing books have been updated.
- (void)catalogUngroupedFeed:(TPPCatalogUngroupedFeed *)catalogUngroupedFeed
              didUpdateBooks:(NSArray *)books;

// Called only when new books have been added.
- (void)catalogUngroupedFeed:(TPPCatalogUngroupedFeed *)catalogUngroupedFeed
                 didAddBooks:(NSArray *)books
                       range:(NSRange)range;

@end

@interface TPPCatalogUngroupedFeed : NSObject

@property (nonatomic, readonly) NSMutableArray *books;
@property (nonatomic, weak) id<TPPCatalogUngroupedFeedDelegate> delegate; // nilable
@property (nonatomic, readonly) NSArray *facetGroups;
@property (nonatomic, readonly) NSURL *openSearchURL; // nilable
@property (nonatomic, readonly) NSString *searchTemplate; // nilable
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) BOOL currentlyFetchingNextURL;
@property (nonatomic, readonly) NSArray<TPPCatalogFacet *> *entryPoints;

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

// In the callback, |ungroupedFeed| will be |nil| if an error occurred.
+ (void)withURL:(NSURL *)URL
useTokenIfAvailable:(BOOL)useTokenIfAvailable
        handler:(void (^)(TPPCatalogUngroupedFeed *ungroupedFeed))handler;

// |feed.type| must be TPPOPDSFeedTypeAcquisitionUngrouped.
- (instancetype)initWithOPDSFeed:(TPPOPDSFeed *)feed;

// This method is used to inform a catalog category that the data of a book at the given index is
// being used elsewhere. This knowledge allows preemptive retrieval of the next URL (if present) so
// that later books will be available upon request. It is important to have a delegate receive
// updates as it's the only way of knowing when data about new books has actually become available.
// It is an error to attempt to prepare for a book index equal to greater than |books.count|,
// something avoidable because book counts never decrease.
- (void)prepareForBookIndex:(NSUInteger)bookIndex;

@end
