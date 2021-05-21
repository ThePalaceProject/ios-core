@class TPPOPDSFeed;
@class TPPCatalogFacet;

@interface TPPCatalogGroupedFeed : NSObject

@property (nonatomic, readonly) NSArray *lanes;
@property (nonatomic, readonly) NSURL *openSearchURL; // nilable
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSArray<TPPCatalogFacet *> *entryPoints;

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

// |feed.type| must be TPPOPDSFeedTypeAcquisitionGrouped.
- (instancetype)initWithOPDSFeed:(TPPOPDSFeed *)feed;

@end
