#import "TPPBook.h"
#import "TPPBookCell.h"
#import "TPPBookDetailViewController.h"
#import "TPPBookRegistry.h"
#import "TPPCatalogSearchViewController.h"
#import "TPPConfiguration.h"
#import "TPPOpenSearchDescription.h"

#import "TPPAccountSignInViewController.h"
#import "TPPOPDS.h"
#import <PureLayout/PureLayout.h>
#import "UIView+TPPViewAdditions.h"

#import "TPPHoldsViewController.h"

#import "Palace-Swift.h"

@interface TPPHoldsViewController ()
<UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout>

// FIXME: It's unclear how "reserved" is different from "held" in this class. These
// two terms are used interchangably in both OPDS and elsewhere in this application.
// Presumably one is for books that are ready for checkout and one is for books that
// are not yet available for checkout. The terminology should be updated appropriately.
@property (nonatomic) NSArray *reservedBooks;
@property (nonatomic) NSArray *heldBooks;
@property (nonatomic) UILabel *instructionsLabel;
@property (nonatomic) UIRefreshControl *refreshControl;
@property (nonatomic) UIBarButtonItem *searchButton;

@end

@implementation TPPHoldsViewController

#pragma mark NSObject

- (instancetype)init
{
  self = [super init];
  if(!self) return nil;

  self.title = NSLocalizedString(@"HoldsViewControllerTitle", nil);
  
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

- (NSArray *)bookArrayForSection:(NSInteger)section
{
  if (self.reservedBooks.count > 0) {
    return section == 0 ? self.reservedBooks : self.heldBooks;
  } else {
    return self.heldBooks;
  }
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.view.backgroundColor = [TPPConfiguration backgroundColor];
  
  self.collectionView.dataSource = self;
  self.collectionView.delegate = self;
  [self.collectionView registerClass:[UICollectionReusableView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"HeaderView"];
  
  self.collectionView.alwaysBounceVertical = YES;
  self.refreshControl = [[UIRefreshControl alloc] init];
  [self.refreshControl addTarget:self action:@selector(didPullToRefresh) forControlEvents:UIControlEventValueChanged];
  [self.collectionView addSubview:self.refreshControl];
  
  // We know that super sets it to a flow layout.
  UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.collectionView.collectionViewLayout;
  layout.headerReferenceSize = CGSizeMake(0, 20);
  
  self.instructionsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.instructionsLabel.hidden = YES;
  self.instructionsLabel.text = NSLocalizedString(@"When you reserve a book from the catalog, it will show up here. Look here from time to time to see if your book is available to download.", nil);
  self.instructionsLabel.textAlignment = NSTextAlignmentCenter;
  self.instructionsLabel.textColor = [UIColor colorWithWhite:0.6667 alpha:1.0];
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

  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    BOOL isSyncing = [TPPBookRegistry sharedRegistry].syncing;
    if(!isSyncing) {
      [self.refreshControl endRefreshing];
      if (self.collectionView.numberOfSections == 0) {
        self.collectionView.contentOffset = CGPointMake(0, -self.collectionView.contentInset.top);
      }
      [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];\
    } else {
      self.navigationItem.leftBarButtonItem.enabled = NO;
    }
  }];
}

#pragma mark UICollectionViewDelegate

- (NSInteger)numberOfSectionsInCollectionView:(__attribute__((unused)) UICollectionView *)collectionView
{
  NSInteger sections = 0;
  if (self.reservedBooks.count > 0) {
    sections++;
  }
  if(self.heldBooks.count > 0) {
    sections++;
  }
  return sections;
}

- (void)collectionView:(__attribute__((unused)) UICollectionView *)collectionView
didSelectItemAtIndexPath:(NSIndexPath *const)indexPath
{
  TPPBook *const book = [self bookArrayForSection:indexPath.section][indexPath.row];
  
  [[[TPPBookDetailViewController alloc] initWithBook:book] presentFromViewController:self];
}

#pragma mark UICollectionViewDataSource

- (NSInteger)collectionView:(__attribute__((unused)) UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section
{
  return [self bookArrayForSection:section].count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
  TPPBook *const book = [self bookArrayForSection:indexPath.section][indexPath.row];
  
  return TPPBookCellDequeue(collectionView, indexPath, book);
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath
{
  UICollectionReusableView *view = nil;
  if(kind == UICollectionElementKindSectionHeader) {
    view = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
    CGRect viewFrame = view.frame;
    viewFrame.size = CGSizeMake(collectionView.frame.size.width, 20);
    view.frame = viewFrame;
    UILabel *title = view.subviews.count > 0 ? view.subviews[0] : nil;
    if(!title) {
      title = [[UILabel alloc] init];
      title.textColor =  [UIApplication darkModeEnabled] ? [UIColor blackColor] : [UIColor whiteColor];
      title.font = [UIFont systemFontOfSize:12];
      [view addSubview:title];
    }
    if([self bookArrayForSection:indexPath.section] == self.reservedBooks) {
      view.layer.backgroundColor = [TPPConfiguration mainColor].CGColor;
      title.text = NSLocalizedString(@"AvailableForCheckoutHeader", nil);
    } else {
      view.layer.backgroundColor = [UIColor colorWithRed:172.0/255.0 green:177.0/255.0 blue:182.0/255 alpha:1.0].CGColor;
      title.text = NSLocalizedString(@"WaitingForAvailabilityHeader", nil);
    }
    [title sizeToFit];
    CGRect frame = title.frame;
    frame.origin = CGPointMake(10, view.frame.size.height / 2 - frame.size.height / 2);
    title.frame = frame;
  } else {
    // This should never happen, but avoid crashing if it does.
    view = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
    view.frame = CGRectZero;
  }
  return view;
}

#pragma mark NYPLBookCellCollectionViewController

- (void)willReloadCollectionViewData
{
  [super willReloadCollectionViewData];
  
  NSArray *books = [[TPPBookRegistry sharedRegistry] heldBooks];
  
  self.instructionsLabel.hidden = !!books.count;
  
  NSMutableArray *reserved = [NSMutableArray array];
  NSMutableArray *held = [NSMutableArray array];
  for(TPPBook *book in books) {
    __block BOOL addedToReserved = NO;
    [book.defaultAcquisition.availability
     matchUnavailable:nil
     limited:nil
     unlimited:nil
     reserved:nil
     ready:^(__unused TPPOPDSAcquisitionAvailabilityReady *_Nonnull ready) {
       [reserved addObject:book];
       addedToReserved = YES;
     }];
    if (!addedToReserved) {
      [held addObject:book];
    }
  }
  self.heldBooks = held;
  self.reservedBooks = reserved;
  [self updateBadge];
}

#pragma mark -

- (void)updateBadge
{
  self.navigationController.tabBarItem.badgeValue = self.reservedBooks.count > 0 ? [@(self.reservedBooks.count) stringValue] : nil;
  if ((NSUInteger)[[UIApplication sharedApplication] applicationIconBadgeNumber] != self.reservedBooks.count) {
    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:self.reservedBooks.count];
  }
}

- (void)didPullToRefresh
{  
  if ([TPPUserAccount sharedAccount].needsAuth) {
    if([[TPPUserAccount sharedAccount] hasCredentials]) {
      [[TPPBookRegistry sharedRegistry] syncWithStandardAlertsOnCompletion];
    } else {
      [TPPAccountSignInViewController requestCredentialsWithCompletion:nil];
      [self.refreshControl endRefreshing];
      [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];
    }
  } else {
    [[TPPBookRegistry sharedRegistry] justLoad];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];
  }
}

- (void)bookRegistryDidChange
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    if([TPPBookRegistry sharedRegistry].syncing == NO) {
      [self.refreshControl endRefreshing];
      [self willReloadCollectionViewData];
    }
  }];
}

- (void)didSelectSearch
{
  NSString *title = NSLocalizedString(@"HoldsViewControllerSearchTitle", nil);
  TPPOpenSearchDescription *searchDescription = [[TPPOpenSearchDescription alloc] initWithTitle:title books:[[TPPBookRegistry sharedRegistry] heldBooks]];
  [self.navigationController
   pushViewController:[[TPPCatalogSearchViewController alloc] initWithOpenSearchDescription:searchDescription]
   animated:YES];
}

- (void)syncBegan
{
  self.navigationItem.leftBarButtonItem.enabled = NO;
}

- (void)syncEnded
{
  self.navigationItem.leftBarButtonItem.enabled = YES;
}

- (void)viewWillTransitionToSize:(CGSize)__unused size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)__unused coordinator
{
  [self.collectionView reloadData];
}

@end
