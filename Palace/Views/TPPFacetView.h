@class TPPFacetView;

@protocol TPPFacetViewDataSource

- (NSUInteger)numberOfFacetGroupsInFacetView:(TPPFacetView *)facetView;

- (NSUInteger)facetView:(TPPFacetView *)facetView
numberOfFacetsInFacetGroupAtIndex:(NSUInteger)index;

- (NSString *)facetView:(TPPFacetView *)facetView nameForFacetGroupAtIndex:(NSUInteger)index;

- (NSString *)facetView:(TPPFacetView *)facetView nameForFacetAtIndexPath:(NSIndexPath *)indexPath;

- (BOOL)facetView:(TPPFacetView *)facetView isActiveFacetForFacetGroupAtIndex:(NSUInteger)index;

- (NSUInteger)facetView:(TPPFacetView *)facetView
activeFacetIndexForFacetGroupAtIndex:(NSUInteger)index;

@end

@protocol TPPFacetViewDelegate

- (void)facetView:(TPPFacetView *)facetView didSelectFacetAtIndexPath:(NSIndexPath *)indexPath;

@end

@interface TPPFacetView : UIView

@property (nonatomic, weak) id<TPPFacetViewDataSource> dataSource;
@property (nonatomic, weak) id<TPPFacetViewDelegate> delegate;

- (void)reloadData;

@end
