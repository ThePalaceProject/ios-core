typedef NS_ENUM(NSInteger, TPPLinearViewContentVerticalAlignment) {
  TPPLinearViewContentVerticalAlignmentTop,
  TPPLinearViewContentVerticalAlignmentMiddle,
  TPPLinearViewContentVerticalAlignmentBottom
};

@interface TPPLinearView : UIView

// This defaults to |TPPLinearViewContentVerticalAlignmentTop|.
@property (nonatomic) TPPLinearViewContentVerticalAlignment contentVerticalAlignment;

// This defaults to 0.
@property (nonatomic) CGFloat padding;

@end
