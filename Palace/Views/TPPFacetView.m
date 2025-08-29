@import PureLayout;

#import "TPPLinearView.h"
#import "UIView+TPPViewAdditions.h"
#import "Palace-Swift.h"

#import "TPPFacetView.h"

@interface TPPFacetView ()

@property (nonatomic) NSMutableArray *groupIndexesToFacetNames;
@property (nonatomic) TPPLinearView *linearView;
@property (nonatomic) UIScrollView *scrollView;

@end

CGFloat const toolbarHeight = 40;

@implementation TPPFacetView

- (void)setDataSource:(id<TPPFacetViewDataSource> const)dataSource
{
  _dataSource = dataSource;
  
  if(self.dataSource && self.delegate) {
    [self reloadData];
  }
}

- (void)setDelegate:(id<TPPFacetViewDelegate> const)delegate
{
  _delegate = delegate;
  
  if(self.dataSource && self.delegate) {
    [self reloadData];
  }
}

- (void)reset
{
  self.groupIndexesToFacetNames = [NSMutableArray array];
 
  [self.scrollView removeFromSuperview];
  
  self.scrollView = [[UIScrollView alloc] init];
  self.scrollView.alwaysBounceHorizontal = YES;
  self.scrollView.showsHorizontalScrollIndicator = NO;
  [self addSubview:self.scrollView];
  
  self.linearView = [[TPPLinearView alloc] init];
  self.linearView.contentVerticalAlignment = TPPLinearViewContentVerticalAlignmentMiddle;
  self.linearView.padding = 3.0;
  [self.scrollView addSubview:self.linearView];
}

- (void)reloadData
{
  self.hidden = YES;

  if(!(self.dataSource && self.delegate)) {
    TPPLOG(@"Ignoring attempt to reload data without a data source and delegate.");
    return;
  }
  
  [self reset];
  
  NSUInteger const groupCount = [self.dataSource numberOfFacetGroupsInFacetView:self];
  
  for(NSUInteger groupIndex = 0; groupIndex < groupCount; ++groupIndex) {
    UIView *const paddingView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 7, 1)];
    [self.linearView addSubview:paddingView];
    
    NSUInteger const facetCount = [self.dataSource
                                   facetView:self
                                   numberOfFacetsInFacetGroupAtIndex:groupIndex];
    
    NSMutableArray *const facetNames = [NSMutableArray arrayWithCapacity:facetCount];
    [self.groupIndexesToFacetNames addObject:facetNames];
    
    for(NSUInteger facetIndex = 0; facetIndex < facetCount; ++facetIndex) {
      NSUInteger const indexes[2] = {groupIndex, facetIndex};
      NSIndexPath *const indexPath = [[NSIndexPath alloc] initWithIndexes:indexes length:2];
      NSString *const facetName = [self.dataSource
                                   facetView:self
                                   nameForFacetAtIndexPath:indexPath];
      [facetNames addObject:facetName];
    }

    UILabel *const groupLabel = [[UILabel alloc] init];
    groupLabel.font = [UIFont palaceFontOfSize:12];
    groupLabel.text = [[self.dataSource facetView:self nameForFacetGroupAtIndex:groupIndex]
                       stringByAppendingString:@":"];
    [self.linearView addSubview:groupLabel];

    TPPRoundedButton *const button = [[TPPRoundedButton alloc] initWithType:TPPRoundedButtonTypeNormal isFromDetailView:NO];
    button.tag = groupIndex;
    button.titleLabel.font = [UIFont palaceFontOfSize:12];
    if([self.dataSource facetView:self isActiveFacetForFacetGroupAtIndex:groupIndex]) {
      NSUInteger const facetIndex = [self.dataSource
                                     facetView:self
                                     activeFacetIndexForFacetGroupAtIndex:groupIndex];
      [button setTitle:self.groupIndexesToFacetNames[groupIndex][facetIndex]
              forState:UIControlStateNormal];
    } else {
      [button setTitle:NSLocalizedString(@"<>", nil)
              forState:UIControlStateNormal];
    }
    [button addTarget:self
               action:@selector(didSelectGroup:)
     forControlEvents:UIControlEventTouchUpInside];
    [self.linearView addSubview:button];
  }
  
  if(groupCount > 0) {
    [self autoSetDimension:ALDimensionHeight toSize:toolbarHeight];
    self.hidden = NO;
    UIView *const paddingView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 7, 1)];
    [self.linearView addSubview:paddingView];
  } else {
    [self autoSetDimension:ALDimensionHeight toSize:0.0];
  }
  
  if(self.superview) {
    [self setNeedsLayout];
  }
}

- (void)didSelectGroup:(UIButton *)sender
{
  UIAlertController *const alertController =
    [UIAlertController
     alertControllerWithTitle:nil
     message:nil
     preferredStyle:UIAlertControllerStyleActionSheet];
  
  alertController.popoverPresentationController.sourceRect = sender.bounds;
  alertController.popoverPresentationController.sourceView = sender;
  
  BOOL const isActive = [self.dataSource
                         facetView:self
                         isActiveFacetForFacetGroupAtIndex:sender.tag];
  
  // If no facet is active, we need to add a cancel button otherwise the user will have no way to
  // abort selecting a facet on the iPhone.
  if(!isActive) {
    [alertController addAction:[UIAlertAction
                                actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                style:UIAlertActionStyleCancel
                                handler:nil]];
  }
  
  // |0| is a dummy value when |!isActive|.
  NSUInteger const activeFacetIndex = (isActive
                                       ? [self.dataSource
                                          facetView:self
                                          activeFacetIndexForFacetGroupAtIndex:sender.tag]
                                       : 0);
  
  __weak TPPFacetView *const weakSelf = self;
  
  NSUInteger facetIndex = 0;
  
  for(NSString *const facet in self.groupIndexesToFacetNames[sender.tag]) {
    NSUInteger indexes[2] = {sender.tag, facetIndex};
    NSIndexPath *const indexPath = [[NSIndexPath alloc] initWithIndexes:indexes length:2];
    if(isActive && facetIndex == activeFacetIndex) {
      [alertController addAction:[UIAlertAction
                                  actionWithTitle:facet
                                  style:UIAlertActionStyleCancel
                                  handler:nil]];
    } else {
      [alertController addAction:[UIAlertAction
                                  actionWithTitle:facet
                                  style:UIAlertActionStyleDefault
                                  handler:^(__attribute__((unused)) UIAlertAction *action) {
                                    [weakSelf.delegate
                                     facetView:weakSelf
                                     didSelectFacetAtIndexPath:indexPath];
                                  }]];
    }
    ++facetIndex;
  }
  
  [TPPPresentationUtils safelyPresent:alertController animated:YES completion:nil];
}

#pragma mark UIView

- (void)layoutSubviews
{
  for(UIView *const view in self.linearView.subviews) {
    [view sizeToFit];
  }
  
  [self.linearView sizeToFit];
  
  self.linearView.frame = CGRectMake(0,
                                     0,
                                     self.linearView.preferredWidth,
                                     CGRectGetHeight(self.frame));
  
  self.scrollView.frame = self.bounds;
  self.scrollView.contentSize = CGSizeMake(CGRectGetWidth(self.linearView.frame),
                                           CGRectGetHeight(self.linearView.frame));
}

- (CGSize)sizeThatFits:(CGSize)size
{
  [self layoutIfNeeded];
  
  CGFloat const w = CGRectGetWidth(self.linearView.frame);
  CGFloat const h = CGRectGetHeight(self.linearView.frame);
  
  if(CGSizeEqualToSize(size, CGSizeZero)) {
    return CGSizeMake(w, h);
  }
  
  return CGSizeMake(w > size.width ? size.width : w, h > size.height ? size.height : h);
}

@end
