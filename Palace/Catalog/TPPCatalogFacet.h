@class TPPOPDSLink;

@interface TPPCatalogFacet : NSObject

@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly) NSURL *href;
@property (nonatomic, readonly) NSString *title; // nilable

// The link provided must have the |TPPOPDSRelationFacet| relation.
+ (TPPCatalogFacet *)catalogFacetWithLink:(TPPOPDSLink *)link;

- (instancetype)initWithActive:(BOOL)active
                          href:(NSURL *)href
                         title:(NSString *)title;

@end
