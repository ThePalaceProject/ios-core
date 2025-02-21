@import PureLayout;

#import "TPPBookDetailViewController.h"
#import "TPPBookNormalCell.h"
#import "TPPCatalogUngroupedFeed.h"
#import "TPPCatalogFacet.h"
#import "TPPCatalogFacetGroup.h"
#import "TPPCatalogFeedViewController.h"
#import "TPPCatalogSearchViewController.h"
#import "TPPConfiguration.h"
#import "TPPFacetView.h"
#import "TPPOpenSearchDescription.h"
#import "TPPReloadView.h"
#import "TPPRemoteViewController.h"
#import "UIView+TPPViewAdditions.h"

#import "Palace-Swift.h"
#import "TPPCatalogUngroupedFeedViewController.h"

static const CGFloat kActivityIndicatorPadding = 20.0;
static const CGFloat kCollectionViewCrossfadeDuration = 0.3;

@interface TPPCatalogUngroupedFeedViewController ()
  <TPPCatalogUngroupedFeedDelegate, TPPFacetViewDelegate, TPPFacetBarViewDelegate, TPPEntryPointViewDelegate, TPPEntryPointViewDataSource,
   UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UIViewControllerPreviewingDelegate>

@property (nonatomic) TPPOpenSearchDescription *searchDescription;
@property (nonatomic) TPPCatalogUngroupedFeed *feed;

@property (nonatomic, weak) TPPRemoteViewController *remoteViewController;
@property (nonatomic) UIRefreshControl *collectionViewRefreshControl;
@property (nonatomic) UIActivityIndicatorView *collectionViewActivityIndicator;
@property (nonatomic) TPPFacetBarView *facetBarView;
@property (nonatomic) TPPFacetViewDefaultDataSource *facetViewDataSource;

@end

@implementation TPPCatalogUngroupedFeedViewController

- (instancetype)initWithUngroupedFeed:(TPPCatalogUngroupedFeed *const)feed
                 remoteViewController:(TPPRemoteViewController *const)remoteViewController
{
  self = [super init];
  if(!self) return nil;
  self.feed = feed;
  self.feed.delegate = self;
  self.remoteViewController = remoteViewController;
  
  return self;
}

- (UIEdgeInsets)scrollIndicatorInsets
{
  return UIEdgeInsetsMake(CGRectGetMaxY(self.facetBarView.frame),
                          0,
                          self.parentViewController.bottomLayoutGuide.length,
                          0);
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.collectionView.dataSource = self;
  self.collectionView.delegate = self;
  self.collectionView.alpha = 0.0;

  if (@available(iOS 11.0, *)) {
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  }
  self.collectionView.alwaysBounceVertical = YES;
  self.collectionViewRefreshControl = [[UIRefreshControl alloc] init];
  [self.collectionViewRefreshControl addTarget:self action:@selector(userDidRefresh:) forControlEvents:UIControlEventValueChanged];
  [self.collectionView addSubview:self.collectionViewRefreshControl];
  
  if(self.feed.openSearchURL) {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
                                              initWithImage:[UIImage imageNamed:@"Search"]
                                              style:UIBarButtonItemStylePlain
                                              target:self
                                              action:@selector(didSelectSearch)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = NSLocalizedString(@"Search", nil);
    self.navigationItem.rightBarButtonItem.enabled = NO;

    // prevent possible unusable Search box when going to Search page
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc]
                                             initWithTitle:NSLocalizedString(@"Back", @"Back button text")
                                             style:UIBarButtonItemStylePlain
                                             target:nil action:nil];
    
    [self fetchOpenSearchDescription];
  }
  
  [self.collectionView reloadData];

  self.facetBarView = [[TPPFacetBarView alloc] initWithOrigin:CGPointZero width:self.view.bounds.size.width];
  self.facetBarView.entryPointView.delegate = self;
  self.facetBarView.entryPointView.dataSource = self;
  self.facetBarView.delegate = self;
  self.facetViewDataSource = [[TPPFacetViewDefaultDataSource alloc] initWithFacetGroups:self.feed.facetGroups];
  self.facetBarView.facetView.delegate = self;
  self.facetBarView.facetView.dataSource = self.facetViewDataSource;
  
  [self.view addSubview:self.facetBarView];
  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeLeading];
  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeTrailing];
  [self.facetBarView autoPinEdgeToSuperviewMargin:ALEdgeTop];

  self.collectionViewActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  self.collectionViewActivityIndicator.hidden = YES;
  [self.collectionViewActivityIndicator startAnimating];
  [self.collectionView addSubview:self.collectionViewActivityIndicator];
  
  [self enable3DTouch];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.navigationController.navigationBar.translucent = NO;
  [self viewWillLayoutSubviews];
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  [UIView animateWithDuration:kCollectionViewCrossfadeDuration animations:^{
    self.collectionView.alpha = 1.0;
    self.facetBarView.alpha = 1.0;
  }];
}

- (void)didMoveToParentViewController:(UIViewController *)parent
{
  [super didMoveToParentViewController:parent];
  
  if(parent) {
    [self updateActivityIndicator];
    
    self.collectionView.scrollIndicatorInsets = [self scrollIndicatorInsets];
    [self.collectionView setContentOffset:CGPointMake(0, -CGRectGetMaxY(self.facetBarView.frame))
                                 animated:NO];
  }
}

- (void)userDidRefresh:(UIRefreshControl *)refreshControl
{
  if ([[self.navigationController.visibleViewController class] isSubclassOfClass:[TPPCatalogFeedViewController class]] &&
      [self.navigationController.visibleViewController respondsToSelector:@selector(load)]) {
    [self.remoteViewController load];
  }
  
  [refreshControl endRefreshing];
  [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];
}

#pragma mark UICollectionViewDataSource

- (NSInteger)collectionView:(__attribute__((unused)) UICollectionView *)collectionView
     numberOfItemsInSection:(__attribute__((unused)) NSInteger)section
{
  return self.feed.books.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
  [self.feed prepareForBookIndex:indexPath.row];
  [self updateActivityIndicator];
  
  TPPBook *const book = self.feed.books[indexPath.row];
  
  return TPPBookCellDequeue(collectionView, indexPath, book);
}

#pragma mark UICollectionViewDelegate

- (void)collectionView:(__attribute__((unused)) UICollectionView *)collectionView
didSelectItemAtIndexPath:(NSIndexPath *const)indexPath
{
  TPPBook *const book = self.feed.books[indexPath.row];
  
  [[[TPPBookDetailViewController alloc] initWithBook:book] presentFromViewController:self];
}

#pragma mark TPPCatalogUngroupedFeedDelegate

- (void)catalogUngroupedFeed:(__attribute__((unused))
                              TPPCatalogUngroupedFeed *)catalogUngroupedFeed
              didUpdateBooks:(__attribute__((unused)) NSArray *)books
{
  [self.collectionView reloadData];
}

- (void)catalogUngroupedFeed:(__attribute__((unused))
                              TPPCatalogUngroupedFeed *)catalogUngroupedFeed
                 didAddBooks:(__attribute__((unused)) NSArray *)books
                       range:(NSRange const)range
{
  NSMutableArray *const indexPaths = [NSMutableArray arrayWithCapacity:range.length];
  
  for(NSUInteger i = 0; i < range.length; ++i) {
    NSUInteger indexes[2] = {0, i + range.location};
    [indexPaths addObject:[NSIndexPath indexPathWithIndexes:indexes length:2]];
  }
  
  // Just reloadData instead of inserting items, to avoid a weird crash (issue #144).
//  [self.collectionView insertItemsAtIndexPaths:indexPaths];
  [self.collectionView reloadData];
}

#pragma mark TPPFacetViewDelegate

- (void)facetView:(__attribute__((unused)) TPPFacetView *)facetView
didSelectFacetAtIndexPath:(NSIndexPath *const)indexPath
{
  TPPCatalogFacetGroup *const group = self.feed.facetGroups[[indexPath indexAtPosition:0]];
  TPPCatalogFacet *const facet = group.facets[[indexPath indexAtPosition:1]];

  NSURL *facetURL = facet.href;
  if (facetURL != nil) {
    [self.remoteViewController loadWithURL:facetURL];
  } else {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                              summary:@"Facet missing the `href` URL to load"
                             metadata:@{
                               @"methodName": @"facetView:didSelectFacetAtIndexPath:",
                               @"facet title": facet.title ?: @"N/A",
                             }];
    [self.remoteViewController showReloadViewWithMessage:NSLocalizedString(@"This URL cannot be found. Please close the app entirely and reload it. If the problem persists, please contact your library's Help Desk.", @"Generic error message indicating that the URL the user was trying to load is missing.")];
  }
}

#pragma mark TPPFacetBarViewDelegate

- (void)present:(UIViewController *)viewController
{
  [self.navigationController pushViewController:viewController animated:YES];
}

#pragma mark TPPEntryPointViewDelegate

- (void)entryPointViewDidSelectWithEntryPointFacet:(TPPCatalogFacet *)entryPointFacet
{
  NSURL *const newURL = entryPointFacet.href;

  if (newURL != nil) {
    [self.remoteViewController loadWithURL:newURL];
  } else {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                              summary:@"Facet missing the `href` URL to load"
                             metadata:@{
                               @"methodName": @"entryPointViewDidSelectWithEntryPointFacet:",
                               @"facet title": entryPointFacet.title ?: @"N/A",
                             }];
    [self.remoteViewController showReloadViewWithMessage:NSLocalizedString(@"This URL cannot be found. Please close the app entirely and reload it. If the problem persists, please contact your library's Help Desk.", @"Generic error message indicating that the URL the user was trying to load is missing.")];
  }
}

- (NSArray<TPPCatalogFacet *> *)facetsForEntryPointView
{
  return self.feed.entryPoints;
}

#pragma mark - 3D Touch

-(void)enable3DTouch
{
  if ([self.traitCollection respondsToSelector:@selector(forceTouchCapability)] &&
      (self.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable)) {
    [self registerForPreviewingWithDelegate:self sourceView:self.view];
  }
}

- (UIViewController *)previewingContext:(id<UIViewControllerPreviewing>)previewingContext
              viewControllerForLocation:(CGPoint)location
{
  CGPoint referencePoint = [self.collectionView convertPoint:location fromView:self.view];
  NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:referencePoint];
  UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
  if (![cell isKindOfClass:[TPPBookNormalCell class]]) {
    return nil;
  }
  TPPBookNormalCell *bookCell = (TPPBookNormalCell *) cell;
  UIViewController *vc = [[UIViewController alloc] init];
  vc.view.tag = indexPath.row;
  UIImageView *imView = [[UIImageView alloc] initWithImage:bookCell.cover.image];
  imView.contentMode = UIViewContentModeScaleAspectFill;
  [vc.view addSubview:imView];
  [imView autoPinEdgesToSuperviewEdges];
  
  vc.preferredContentSize = CGSizeZero;
  previewingContext.sourceRect = [self.view convertRect:cell.frame fromView:[cell superview]];
  
  return vc;
}

- (void)previewingContext:(__unused id<UIViewControllerPreviewing>)previewingContext
     commitViewController:(UIViewController *)viewControllerToCommit
{
  TPPBook *const book = self.feed.books[viewControllerToCommit.view.tag];
  [[[TPPBookDetailViewController alloc] initWithBook:book] presentFromViewController:self];
}

#pragma mark -

- (void)updateActivityIndicator
{
  UIEdgeInsets insets = [self scrollIndicatorInsets];
  if(self.feed.currentlyFetchingNextURL) {
    insets.bottom += kActivityIndicatorPadding + self.collectionViewActivityIndicator.frame.size.height;
    CGRect frame = self.collectionViewActivityIndicator.frame;
    frame.origin = CGPointMake(CGRectGetMidX(self.collectionView.frame) - frame.size.width/2,
                               self.collectionView.contentSize.height + kActivityIndicatorPadding/2);
    self.collectionViewActivityIndicator.frame = frame;
  }
  self.collectionViewActivityIndicator.hidden = !self.feed.currentlyFetchingNextURL;
  self.collectionView.contentInset = insets;
}

- (void)didSelectSearch
{
  [self.navigationController
   pushViewController:[[TPPCatalogSearchViewController alloc]
                       initWithOpenSearchDescription:self.searchDescription]
   animated:YES];
}

- (void)fetchOpenSearchDescription
{
  [TPPOpenSearchDescription
   withURL:self.feed.openSearchURL
   shouldResetCache:NO
   completionHandler:^(TPPOpenSearchDescription *const description) {
     [[NSOperationQueue mainQueue] addOperationWithBlock:^{
       self.searchDescription = description;
       self.navigationItem.rightBarButtonItem.enabled = YES;
     }];
   }];
}

@end
