
#import "TPPBookCell.h"
#import "TPPBookDetailViewController.h"
#import "TPPCatalogSearchViewController.h"
#import "TPPConfiguration.h"
#import "TPPFacetView.h"
#import "TPPOpenSearchDescription.h"
#import "TPPAccountSignInViewController.h"

#import "NSDate+NYPLDateAdditions.h"
#import "TPPMyBooksDownloadCenter.h"
#import <PureLayout/PureLayout.h>
#import "UIView+TPPViewAdditions.h"

#import "TPPMyBooksViewController.h"

#import "Palace-Swift.h"

// order-dependent
typedef NS_ENUM(NSInteger, Group) {
  GroupSortBy
};

// order-dependent
typedef NS_ENUM(NSInteger, FacetSort) {
  FacetSortAuthor,
  FacetSortTitle
};

@interface TPPMyBooksContainerView : UIView
@property (nonatomic) NSArray *accessibleElements;
@end

@implementation TPPMyBooksContainerView

#pragma mark Accessibility

- (BOOL) isAccessibilityElement {
  return NO;
}

- (NSInteger) accessibilityElementCount {
  return self.accessibleElements.count;
}

- (id) accessibilityElementAtIndex:(NSInteger)index {
  return self.accessibleElements[index];
}

- (NSInteger) indexOfAccessibilityElement:(id)element {
  return [self.accessibleElements indexOfObject:element];
}

@end

@interface TPPMyBooksViewController ()
  <TPPFacetViewDataSource, TPPFacetViewDelegate, TPPFacetBarViewDelegate, UICollectionViewDataSource,
   UICollectionViewDelegate, UICollectionViewDelegateFlowLayout>

@property (nonatomic) FacetSort activeFacetSort;
@property (nonatomic) NSArray *books;
@property (nonatomic) TPPFacetBarView *facetBarView;
@property (nonatomic) UILabel *instructionsLabel;
@property (nonatomic) UIRefreshControl *refreshControl;
@property (nonatomic) UIBarButtonItem *searchButton;
@property (nonatomic) TPPMyBooksContainerView *containerView;
@end

@implementation TPPMyBooksViewController

#pragma mark NSObject

- (instancetype)init
{
  self = [super init];
  if(!self) return nil;

  self.title = NSLocalizedString(@"MyBooksViewControllerTitle", nil);
  
  [self willReloadCollectionViewData];
  
  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(bookRegistryDidChange)
   name:NSNotification.TPPBookRegistryDidChange
   object:nil];
  
  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(syncEnded)
   name:NSNotification.TPPSyncEnded object:nil];
  
  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(syncBegan)
   name:NSNotification.TPPSyncBegan object:nil];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.view.backgroundColor = [TPPConfiguration backgroundColor];
  
  self.activeFacetSort = FacetSortAuthor;
  
  self.collectionView.dataSource = self;
  self.collectionView.delegate = self;

  self.collectionView.alwaysBounceVertical = YES;
  self.refreshControl = [[UIRefreshControl alloc] init];
  [self.refreshControl addTarget:self action:@selector(didPullToRefresh) forControlEvents:UIControlEventValueChanged];
  [self.collectionView addSubview:self.refreshControl];
  
  self.facetBarView = [[TPPFacetBarView alloc] initWithOrigin:CGPointZero width:0];
  self.facetBarView.facetView.dataSource = self;
  self.facetBarView.facetView.delegate = self;
  self.facetBarView.delegate = self;

  [self.view addSubview:self.facetBarView];
  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeLeading];
  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeTrailing];
  [self.facetBarView autoPinEdgeToSuperviewMargin:ALEdgeTop];

  self.instructionsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.instructionsLabel.hidden = YES;
  self.instructionsLabel.text = NSLocalizedString(@"MyBooksGoToCatalog", nil);
  self.instructionsLabel.textAlignment = NSTextAlignmentCenter;
  self.instructionsLabel.textColor = [UIColor colorWithWhite:0.6667 alpha:1.0];
  self.instructionsLabel.font = [UIFont palaceFontOfSize:18.0];
  self.instructionsLabel.numberOfLines = 0;
  [self.view addSubview:self.instructionsLabel];
  [self.instructionsLabel autoCenterInSuperview];
  [self.instructionsLabel autoSetDimension:ALDimensionWidth toSize:300.0];
  
  self.searchButton = [[UIBarButtonItem alloc]
                       initWithImage:[UIImage imageNamed:@"Search"]
                       style:UIBarButtonItemStylePlain
                       target:self
                       action:@selector(didSelectSearch)];
  self.searchButton.accessibilityLabel = NSLocalizedString(@"Search", nil);
  self.navigationItem.rightBarButtonItem = self.searchButton;

  // prevent possible unusable Search box when going to Search page
  self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc]
                                           initWithTitle:NSLocalizedString(@"Back", @"Back button text")
                                           style:UIBarButtonItemStylePlain
                                           target:nil action:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  [self.navigationController setNavigationBarHidden:NO];
  self.navigationController.navigationBar.tintColor = [TPPConfiguration iconColor];
  self.navigationItem.title = NSLocalizedString(@"MyBooksViewControllerTitle", nil);
  [TPPBookRegistry.shared sync];
}

- (void)viewWillLayoutSubviews
{
  UIEdgeInsets contentInset = self.collectionView.contentInset;
  if (@available(iOS 11.0, *)) {
    // In iOS >= 11.0, we only need to account for our custom views.
    contentInset.top = CGRectGetHeight(self.facetBarView.frame);
  } else {
    // In older versions of iOS, we need to account for everything.
    contentInset.top = CGRectGetMaxY(self.facetBarView.frame);
  }
  self.collectionView.contentInset = contentInset;
  self.collectionView.scrollIndicatorInsets = contentInset;
}

#pragma mark UICollectionViewDelegate

- (void)collectionView:(__attribute__((unused)) UICollectionView *)collectionView
didSelectItemAtIndexPath:(NSIndexPath *const)indexPath
{
  TPPBook *const book = self.books[indexPath.row];
  
  [[[TPPBookDetailViewController alloc] initWithBook:book] presentFromViewController:self];
}

#pragma mark UICollectionViewDataSource

- (NSInteger)collectionView:(__attribute__((unused)) UICollectionView *)collectionView
     numberOfItemsInSection:(__attribute__((unused)) NSInteger)section
{
  return self.books.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
  TPPBook *const book = self.books[indexPath.row];
  
  return TPPBookCellDequeue(collectionView, indexPath, book);
}

#pragma mark NYPLBookCellCollectionViewController

- (void)willReloadCollectionViewData
{
  [super willReloadCollectionViewData];
  
  NSArray *books = [[TPPBookRegistry shared] myBooks];
  
  self.instructionsLabel.hidden = !!books.count;
    
  switch(self.activeFacetSort) {
    case FacetSortAuthor: {
      self.books = [books sortedArrayUsingComparator:
                    ^NSComparisonResult(TPPBook *const a, TPPBook *const b) {
                      // myBooks is generated from a dictionary and the order of elements may change every time
                      // elements with same authors or title change their position in the view
                      // comparing "authors title" or "title authors" to avoid this.
                      NSString *aString = [NSString stringWithFormat:@"%@ %@", a.authors, a.title];
                      NSString *bString = [NSString stringWithFormat:@"%@ %@", b.authors, a.title];
                      return [aString compare:bString options:NSCaseInsensitiveSearch];
                    }];
      break;
    }
    case FacetSortTitle: {
      self.books = [books sortedArrayUsingComparator:
                    ^NSComparisonResult(TPPBook *const a, TPPBook *const b) {
                      NSString *aString = [NSString stringWithFormat:@"%@ %@", a.title, a.authors];
                      NSString *bString = [NSString stringWithFormat:@"%@ %@", b.title, a.authors];
                      return [aString compare:bString options:NSCaseInsensitiveSearch];
                    }];
      break;
    }
  }
}

#pragma mark NYPLFacetViewDataSource

- (NSUInteger)numberOfFacetGroupsInFacetView:(__attribute__((unused)) TPPFacetView *)facetView
{
  return 1;
}

- (NSUInteger)facetView:(__attribute__((unused)) TPPFacetView *)facetView
numberOfFacetsInFacetGroupAtIndex:(__attribute__((unused)) NSUInteger)index
{
  return 2;
}

- (NSString *)facetView:(__attribute__((unused)) TPPFacetView *)facetView
nameForFacetGroupAtIndex:(NSUInteger const)index
{
  return @[NSLocalizedString(@"MyBooksViewControllerGroupSortBy", nil),
           ][index];
}

- (NSString *)facetView:(__attribute__((unused)) TPPFacetView *)facetView
nameForFacetAtIndexPath:(NSIndexPath *const)indexPath
{
  switch([indexPath indexAtPosition:0]) {
    case GroupSortBy:
      switch([indexPath indexAtPosition:1]) {
        case FacetSortAuthor:
          return NSLocalizedString(@"MyBooksViewControllerFacetAuthor", nil);
        case FacetSortTitle:
          return NSLocalizedString(@"MyBooksViewControllerFacetTitle", nil);
      }
      break;
  }
  
  @throw NSInternalInconsistencyException;
}

- (BOOL)facetView:(__attribute__((unused)) TPPFacetView *)facetView
isActiveFacetForFacetGroupAtIndex:(__attribute__((unused)) NSUInteger)index
{
  return YES;
}

- (NSUInteger)facetView:(__attribute__((unused)) TPPFacetView *)facetView
activeFacetIndexForFacetGroupAtIndex:(NSUInteger const)index
{
  switch(index) {
    case GroupSortBy:
      return self.activeFacetSort;
  }
  
  @throw NSInternalInconsistencyException;
}

#pragma mark TPPFacetBarViewDelegate

- (void)present:(UIViewController *)viewController
{
  [self.navigationController pushViewController:viewController animated:YES];
}

#pragma mark NYPLFacetViewDelegate

- (void)facetView:(TPPFacetView *const)facetView
didSelectFacetAtIndexPath:(NSIndexPath *const)indexPath
{
  switch([indexPath indexAtPosition:0]) {
    case GroupSortBy:
      switch([indexPath indexAtPosition:1]) {
        case FacetSortAuthor:
          self.activeFacetSort = FacetSortAuthor;
          goto OK;
        case FacetSortTitle:
          self.activeFacetSort = FacetSortTitle;
          goto OK;
      }
      break;
  }
  
  @throw NSInternalInconsistencyException;
  
OK:
  
  [facetView reloadData];
  [self willReloadCollectionViewData];
  [self.collectionView reloadData];
}

#pragma mark -

/// Reloads book registry data
- (void)reloadData
{
  if ([TPPUserAccount sharedAccount].needsAuth && ![[TPPUserAccount sharedAccount] hasCredentials]) {
    [TPPAccountSignInViewController requestCredentialsWithCompletion:nil];
    [self.refreshControl endRefreshing];
  } else {
    [[TPPBookRegistry shared] sync];
  }
}

- (void)didPullToRefresh
{
  if (AccountsManager.shared.currentAccount.loansUrl) {
    [self reloadData];
  } else {
    [self.refreshControl endRefreshing];
  }
}

- (void)didSelectSearch
{
  NSString *title = NSLocalizedString(@"MyBooksViewControllerSearchTitle", nil);
  TPPOpenSearchDescription *searchDescription = [[TPPOpenSearchDescription alloc] initWithTitle:title books:self.books];
  [self.navigationController
   pushViewController:[[TPPCatalogSearchViewController alloc] initWithOpenSearchDescription:searchDescription]
   animated:YES];
}

- (void)bookRegistryDidChange
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self willReloadCollectionViewData];
  });
}

- (void)syncBegan
{
}

- (void)syncEnded
{
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.refreshControl endRefreshing];
    [self willReloadCollectionViewData];
  });
}

- (void)viewWillTransitionToSize:(CGSize)__unused size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)__unused coordinator
{
  [self.collectionView reloadData];
}

@end
