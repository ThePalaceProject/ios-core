@interface UIView (TPPViewAdditions)

@property (nonatomic, readonly) CGFloat preferredHeight;
@property (nonatomic, readonly) CGFloat preferredWidth;

- (void)centerInSuperview;

- (void)centerInSuperviewWithOffset:(CGPoint)offset;

- (void)integralizeFrame;

@end
