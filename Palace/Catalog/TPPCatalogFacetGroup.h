@class TPPOPDSFeed;

@interface TPPCatalogFacetGroup : NSObject

@property (nonatomic, readonly) NSArray *facets;
@property (nonatomic, readonly) NSString *name;

- (instancetype)initWithFacets:(NSArray *)facets
                          name:(NSString *)name;

@end
