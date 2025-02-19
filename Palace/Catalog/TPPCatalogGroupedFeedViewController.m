@import PureLayout;

#import "TPPBookDetailViewController.h"

#import "TPPCatalogFeedViewController.h"
#import "TPPCatalogGroupedFeed.h"
#import "TPPCatalogLane.h"
#import "TPPCatalogLaneCell.h"
#import "TPPCatalogSearchViewController.h"
#import "TPPConfiguration.h"
#import "TPPIndeterminateProgressView.h"
#import "TPPOpenSearchDescription.h"
#import "TPPXML.h"
#import "UIView+TPPViewAdditions.h"

#import "TPPCatalogFacet.h"
#import "Palace-Swift.h"
#import "TPPCatalogGroupedFeedViewController.h"

static CGFloat const kRowHeight = 115.0;
static CGFloat const kSectionHeaderHeight = 50.0;
static CGFloat const kTableViewInsetAdjustmentWithEntryPoints = -8;
static CGFloat const kTableViewCrossfadeDuration = 0.3;


@interface TPPCatalogGroupedFeedViewController ()
  <TPPCatalogLaneCellDelegate, TPPEntryPointViewDelegate, TPPFacetBarViewDelegate, TPPEntryPointViewDataSource, UITableViewDataSource, UITableViewDelegate, UIViewControllerPreviewingDelegate>

@property (nonatomic, weak) TPPRemoteViewController *remoteViewController;
@property (nonatomic) NSMutableDictionary *bookIdentifiersToImages;
@property (nonatomic) NSMutableDictionary *cachedLaneCells;
@property (nonatomic) TPPCatalogGroupedFeed *feed;
@property (nonatomic) NSUInteger indexOfNextLaneRequiringImageDownload;
@property (nonatomic) UIRefreshControl *refreshControl;
@property (nonatomic) TPPOpenSearchDescription *searchDescription;
@property (nonatomic) TPPFacetBarView *facetBarView;
@property (nonatomic) UITableView *tableView;
@property (nonatomic) TPPBook *mostRecentBookSelected;
@property (nonatomic) int tempBookPosition;
@property (nonatomic) UITraitCollection *previouslyProcessedTraits;
@end

@implementation TPPCatalogGroupedFeedViewController

#pragma mark NSObject

- (instancetype)initWithGroupedFeed:(TPPCatalogGroupedFeed *const)feed
               remoteViewController:(TPPRemoteViewController *const)remoteViewController
{
  self = [super init];
  if(!self) return nil;

  self.bookIdentifiersToImages = [NSMutableDictionary dictionary];
  self.cachedLaneCells = [NSMutableDictionary dictionary];
  self.feed = feed;
  self.remoteViewController = remoteViewController;

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(userDidCloseBookDetail:)
                                               name:NSNotification.TPPBookDetailDidClose
                                             object:nil];

  return self;
}

- (void)dealloc
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];

  self.view.backgroundColor = [TPPConfiguration backgroundColor];

  self.refreshControl = [[UIRefreshControl alloc] init];
  [self.refreshControl addTarget:self action:@selector(userDidRefresh:) forControlEvents:UIControlEventValueChanged];

  self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
  self.tableView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight);
  self.tableView.alpha = 0.0;
  self.tableView.backgroundColor = [TPPConfiguration backgroundColor];
  self.tableView.dataSource = self;
  self.tableView.delegate = self;
  self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
  self.tableView.allowsSelection = NO;
  if (@available(iOS 11.0, *)) {
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  }
  [self.tableView addSubview:self.refreshControl];
  [self.view addSubview:self.tableView];

  self.facetBarView = [[TPPFacetBarView alloc] initWithOrigin:CGPointZero width:self.view.bounds.size.width];
  self.facetBarView.entryPointView.delegate = self;
  self.facetBarView.entryPointView.dataSource = self;
  self.facetBarView.delegate = self;

  [self.view addSubview:self.facetBarView];

  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeLeading];
  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeTrailing];
  [self.facetBarView autoPinEdgeToSuperviewMargin:ALEdgeTop];

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

  [self downloadImages];
  [self enable3DTouch];
}

- (void)didMoveToParentViewController:(UIViewController *)parent
{
  [super didMoveToParentViewController:parent];

  if(parent) {
    CGFloat top = parent.topLayoutGuide.length;

    if (self.facetBarView.frame.size.height > 0) {
      top = CGRectGetMaxY(self.facetBarView.frame) + kTableViewInsetAdjustmentWithEntryPoints;
    }

    CGFloat bottom = parent.bottomLayoutGuide.length;

    UIEdgeInsets insets = UIEdgeInsetsMake(top, 0, bottom, 0);
    self.tableView.contentInset = insets;
    self.tableView.scrollIndicatorInsets = insets;
    [self.tableView setContentOffset:CGPointMake(0, -top) animated:NO];
  }
}

- (void)didReceiveMemoryWarning
{
  [super didReceiveMemoryWarning];

  [self.cachedLaneCells removeAllObjects];
}

- (void)userDidRefresh:(UIRefreshControl *)refreshControl
{
  if ([[self.navigationController.visibleViewController class] isSubclassOfClass:[TPPCatalogFeedViewController class]] &&
      [self.navigationController.visibleViewController respondsToSelector:@selector(load)]) {
    TPPCatalogFeedViewController *viewController = (TPPCatalogFeedViewController *)self.navigationController.visibleViewController;
    [viewController load];
  }

  [refreshControl endRefreshing];
  [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.navigationController.navigationBar.translucent = NO;
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];

  [UIView animateWithDuration:kTableViewCrossfadeDuration animations:^{
    self.tableView.alpha = 1.0;
    self.facetBarView.alpha = 1.0;
  }];

  if (!self.presentedViewController) {
    self.mostRecentBookSelected = nil;
  }
}

// Transition book detail view between Form Sheet and Nav Controller
// when changing between compact and regular size classes
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraits
{
  [super traitCollectionDidChange:previousTraits];

  // for some reason when we background the app this method is called twice.
  // So if we see that we already handled the previous traits, we bail early.
  if ([self.previouslyProcessedTraits isEqual:previousTraits]) {
    return;
  }
  self.previouslyProcessedTraits = previousTraits;
  
  // if there are no changes in size class traits, there's no need to adjust
  // the way we present the book details
  UITraitCollection *currentTraits = self.traitCollection;
  if (previousTraits.horizontalSizeClass == currentTraits.horizontalSizeClass
      && previousTraits.verticalSizeClass == currentTraits.verticalSizeClass) {
    return;
  }

  if (!self.mostRecentBookSelected) {
    return;
  }

  if (self.presentedViewController) {
    [self dismissViewControllerAnimated:NO completion:nil];
  } else if ([self.navigationController viewControllers].count > 1) {
    [self.navigationController popToRootViewControllerAnimated:NO];
  }

  TPPLOG_F(@"Presenting book: %@", [self.mostRecentBookSelected loggableShortString]);
  [[[TPPBookDetailViewController alloc] initWithBook:self.mostRecentBookSelected] presentFromViewController:self];
}

#pragma mark UITableViewDataSource

- (UITableViewCell *)tableView:(__attribute__((unused)) UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *const)indexPath
{
  // Caching cells helps with performance and lets us retain horizontal scroll positions. Cells are
  // only stored in |self.cachedLaneCells| if they are final.
  UITableViewCell *const cachedCell = self.cachedLaneCells[indexPath];
  if(cachedCell) {
    return cachedCell;
  }
  
  if(indexPath.section < (NSInteger) self.indexOfNextLaneRequiringImageDownload) {
    TPPCatalogLaneCell *const cell =
    [[TPPCatalogLaneCell alloc]
     initWithLaneIndex:indexPath.section
     books:((TPPCatalogLane *) self.feed.lanes[indexPath.section]).books
     bookIdentifiersToImages:self.bookIdentifiersToImages];
    cell.delegate = self;
    self.cachedLaneCells[indexPath] = cell;
    return cell;
  } else {
    UITableViewCell *const cell = [[UITableViewCell alloc] init];
    CGRect const progressViewFrame = CGRectMake(5,
                                                0,
                                                CGRectGetWidth(cell.contentView.bounds) - 10,
                                                CGRectGetHeight(cell.contentView.bounds));
    TPPIndeterminateProgressView *const progressView = [[TPPIndeterminateProgressView alloc]
                                                         initWithFrame:progressViewFrame];
    progressView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight);
    progressView.color = [UIColor colorWithWhite:0.95 alpha:1.0];
    progressView.layer.borderWidth = 2;
    progressView.speedMultiplier = 2.0;
    [progressView startAnimating];
    [cell.contentView addSubview:progressView];
    return cell;
  }
}

- (NSInteger)tableView:(__attribute__((unused)) UITableView *)tableView
 numberOfRowsInSection:(__attribute__((unused)) NSInteger)section
{
  return 1;
}

- (NSInteger)numberOfSectionsInTableView:(__attribute__((unused)) UITableView *)tableView
{
  return self.feed.lanes.count;
}

#pragma mark UITableViewDelegate

- (CGFloat)tableView:(__attribute__((unused)) UITableView *)tableView
heightForRowAtIndexPath:(__attribute__((unused)) NSIndexPath *)indexPath
{
  return kRowHeight;
}

- (CGFloat)tableView:(__attribute__((unused)) UITableView *)tableView
heightForHeaderInSection:(__attribute__((unused)) NSInteger)section
{
  return kSectionHeaderHeight;
}

- (UIView *)tableView:(__attribute__((unused)) UITableView *)tableView
viewForHeaderInSection:(NSInteger const)section
{
  CGRect const frame = CGRectMake(0, 0, CGRectGetWidth(self.tableView.frame), kSectionHeaderHeight);
  UIView *const view = [[UIView alloc] initWithFrame:frame];
  view.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  view.backgroundColor = [[TPPConfiguration backgroundColor] colorWithAlphaComponent:0.9];
  
  {
    UIButton *const button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [UIFont palaceFontOfSize:21];
    NSString *const title = ((TPPCatalogLane *) self.feed.lanes[section]).title;
    [button setTitle:title forState:UIControlStateNormal];
    [button sizeToFit];
    if (CGRectGetWidth(button.frame) > self.tableView.frame.size.width - 100) {
      button.frame = CGRectMake(7, 5, self.tableView.frame.size.width - 100, CGRectGetHeight(button.frame));
    } else {
      button.frame = CGRectMake(7, 5, CGRectGetWidth(button.frame), CGRectGetHeight(button.frame));
    }
    button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    button.tag = section;
    [button addTarget:self
               action:@selector(didSelectCategory:)
     forControlEvents:UIControlEventTouchUpInside];
    button.exclusiveTouch = YES;
    [view addSubview:button];
  }
  
  {
    UIButton *const button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.titleLabel.font = [UIFont palaceFontOfSize:13];
    NSString *const title = NSLocalizedString(@"More...", nil);
    [button setTitle:title forState:UIControlStateNormal];
    [button sizeToFit];
    button.frame = CGRectMake(CGRectGetWidth(view.frame) - CGRectGetWidth(button.frame) - 10,
                              13,
                              CGRectGetWidth(button.frame),
                              CGRectGetHeight(button.frame));
    button.tag = section;
    TPPCatalogLane *const lane = self.feed.lanes[button.tag];
    button.accessibilityLabel = [[NSString alloc] initWithFormat:NSLocalizedString(@"More %@ books", nil), lane.title];
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [button addTarget:self
               action:@selector(didSelectCategory:)
     forControlEvents:UIControlEventTouchUpInside];
    button.exclusiveTouch = YES;
    [view addSubview:button];
  }
  return view;
}

#pragma mark TPPCatalogLaneCellDelegate

- (void)catalogLaneCell:(TPPCatalogLaneCell *const)cell
     didSelectBookIndex:(NSUInteger const)bookIndex
{
  TPPCatalogLane *const lane = self.feed.lanes[cell.laneIndex];
  TPPBook *const feedBook = lane.books[bookIndex];
  
  TPPBook *const localBook = [[TPPBookRegistry shared] bookForIdentifier:feedBook.identifier];
  TPPBook *const book = (localBook != nil) ? localBook : feedBook;
  TPPLOG_F(@"Presenting book: %@", [book loggableShortString]);
  BookDetailHostingController *bookDetailVC = [[BookDetailHostingController alloc] initWithBook:book];
//  [self presentViewController:bookDetailVC animated:YES completion:nil];
  [self.navigationController pushViewController:bookDetailVC animated:true];


  self.mostRecentBookSelected = book;
}

#pragma mark TPPFacetBarViewDelegate

- (void)present:(UIViewController *)viewController
{
  [self.navigationController pushViewController:viewController animated:YES];
}

#pragma mark - 3D Touch

- (void)enable3DTouch
{
  if ([self.traitCollection respondsToSelector:@selector(forceTouchCapability)] &&
      (self.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable)) {
    [self registerForPreviewingWithDelegate:self sourceView:self.tableView];
  }
}

- (UIViewController *)previewingContext:(id<UIViewControllerPreviewing>)previewingContext
              viewControllerForLocation:(CGPoint)location
{
  NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:location];
  UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
  if (![cell isKindOfClass:[TPPCatalogLaneCell class]]) {
    return nil;
  }
  UIViewController *vc = [[UIViewController alloc] init];
  TPPCatalogLaneCell *laneCell = (TPPCatalogLaneCell *) cell;
  vc.view.tag = laneCell.laneIndex;
  
  for (UIButton *button in laneCell.buttons) {
    CGPoint referencePoint = [[button superview] convertPoint:location fromView:self.tableView];
    if (CGRectContainsPoint(button.frame, referencePoint)) {
      UIImageView *imgView = [[UIImageView alloc] initWithImage:button.imageView.image];
      imgView.contentMode = UIViewContentModeScaleAspectFill;
      [vc.view addSubview:imgView];
      [imgView autoPinEdgesToSuperviewEdges];
      vc.preferredContentSize = CGSizeZero;
      previewingContext.sourceRect = [self.tableView convertRect:button.frame fromView:[button superview]];
      
      self.tempBookPosition = (int)button.tag;
      
      return vc;
    }
  }
  return nil;
}

- (void)previewingContext:(__unused id<UIViewControllerPreviewing>)previewingContext
     commitViewController:(UIViewController *)viewControllerToCommit
{
  TPPCatalogLane *const lane = self.feed.lanes[viewControllerToCommit.view.tag];
  TPPBook *const feedBook = lane.books[self.tempBookPosition];
  TPPBook *const localBook = [[TPPBookRegistry shared] bookForIdentifier:feedBook.identifier];
  TPPBook *const book = (localBook != nil) ? localBook : feedBook;
  TPPLOG_F(@"Presenting book: %@", [book loggableShortString]);
  [[[TPPBookDetailViewController alloc] initWithBook:book] presentFromViewController:self];
}

#pragma mark - TPPEntryPointViewDataSource

- (void)entryPointViewDidSelectWithEntryPointFacet:(TPPCatalogFacet *)entryPointFacet {
  NSURL *const newURL = entryPointFacet.href;

  if (newURL != nil) {
    [self.remoteViewController loadWithURL:newURL];
  } else {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                              summary:@"Catalog facet missing href URL"
                             metadata:nil];
    [self.remoteViewController showReloadViewWithMessage:NSLocalizedString(@"This URL cannot be found. Please close the app entirely and reload it. If the problem persists, please contact your library's Help Desk.", @"Generic error message indicating that the URL the user was trying to load is missing.")];
  }
}

- (NSArray<TPPCatalogFacet *> *)facetsForEntryPointView
{
  return self.feed.entryPoints;
}

#pragma mark -

- (void)downloadImages
{
  if(self.indexOfNextLaneRequiringImageDownload >= self.feed.lanes.count) {
    [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:NO];
    return;
  }
  
  [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:YES];
  
  TPPCatalogLane *const lane = self.feed.lanes[self.indexOfNextLaneRequiringImageDownload];
  
  [[TPPBookRegistry shared]
   thumbnailImagesForBooks:[NSSet setWithArray:lane.books]
   handler:^(NSDictionary *const bookIdentifiersToImages) {
     [self.bookIdentifiersToImages addEntriesFromDictionary:bookIdentifiersToImages];
     // We update this before reloading so that the delegate accurately knows which lanes already
     // have had their covers downloaded.
     ++self.indexOfNextLaneRequiringImageDownload;
    [self.tableView reloadData];
    [self downloadImages];
   }];
}

- (void)didSelectCategory:(UIButton *const)button
{
  TPPCatalogLane *const lane = self.feed.lanes[button.tag];

  NSURL *urlToLoad = lane.subsectionURL;
  if (urlToLoad == nil) {
    NSString *msg = [NSString stringWithFormat:@"Lane %@ has no subsection URL to display category",
                     lane.title];
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                              summary:msg
                             metadata:@{
                               @"methodName": @"didSelectCategory:"
                             }];
  }

  UIViewController *const viewController = [[TPPCatalogFeedViewController alloc]
                                            initWithURL:urlToLoad];
  
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 150)];
  label.numberOfLines = 0;
  label.lineBreakMode = NSLineBreakByWordWrapping;
  label.textAlignment = NSTextAlignmentCenter;
  label.font = [UIFont semiBoldPalaceFontOfSize: 16];
  label.text = lane.title;
  label.accessibilityLabel = @"navigationTitle";
  viewController.navigationItem.titleView = label;

  [self.navigationController pushViewController:viewController animated:YES];
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

- (void)userDidCloseBookDetail:(NSNotification *)notif
{
  if ([notif.object isKindOfClass:[TPPBook class]]) {
    TPPBook *book = notif.object;

    // if we closed the book detail page for the given book, we should no
    // longer track its ID because don't have to present it anymore.
    if ([self.mostRecentBookSelected.identifier isEqualToString:book.identifier]) {
      self.mostRecentBookSelected = nil;
    }
  }
}

@end
