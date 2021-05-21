@class TPPCatalogLaneCell;

@protocol TPPCatalogLaneCellDelegate

- (void)catalogLaneCell:(TPPCatalogLaneCell *)cell didSelectBookIndex:(NSUInteger)bookIndex;

@end

@interface TPPCatalogLaneCell : UITableViewCell

@property (nonatomic, weak) id<TPPCatalogLaneCellDelegate> delegate;
@property (nonatomic, readonly) NSUInteger laneIndex;

@property (nonatomic, readonly) NSArray *buttons;
@property (nonatomic, readonly) UIScrollView *scrollView;


+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;
- (id)initWithCoder:(NSCoder *)aDecoder NS_UNAVAILABLE;
- (id)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (id)initWithStyle:(UITableViewCellStyle)style
    reuseIdentifier:(NSString *)reuseIdentifier NS_UNAVAILABLE;

// designated initializer
- (instancetype)initWithLaneIndex:(NSUInteger)laneIndex
                            books:(NSArray *)books
          bookIdentifiersToImages:(NSDictionary *)bookIdentifiersToImages;

@end
