// TODO: This class duplicates much of the functionality of TPPCatalogUngroupedFeedViewController.
// After it is complete, the common portions must be factored out.


#import "NSString+TPPStringAdditions.h"

#import "TPPBookCell.h"
#import "TPPBookDetailViewController.h"
#import "TPPCatalogUngroupedFeed.h"
#import "TPPOpenSearchDescription.h"
#import "TPPReloadView.h"
#import "UIView+TPPViewAdditions.h"
#import "Palace-Swift.h"

#import "TPPCatalogSearchViewController.h"

@interface TPPCatalogSearchViewController ()
  <TPPCatalogUngroupedFeedDelegate, TPPEntryPointViewDataSource, TPPEntryPointViewDelegate, UICollectionViewDelegate, UICollectionViewDataSource, UISearchBarDelegate>

@property (nonatomic) TPPOpenSearchDescription *searchDescription;
@property (nonatomic) TPPCatalogUngroupedFeed *feed;
@property (nonatomic) NSArray *books;

@property (nonatomic) UIActivityIndicatorView *searchActivityIndicatorView;
@property (nonatomic) UILabel *searchActivityIndicatorLabel;
@property (nonatomic) TPPReloadView *reloadView;
@property (nonatomic) UISearchBar *searchBar;
@property (nonatomic) UILabel *noResultsLabel;
@property (nonatomic) TPPFacetBarView *facetBarView;
@property (nonatomic) NSTimer *debounceTimer;

@end

@implementation TPPCatalogSearchViewController

- (instancetype)initWithOpenSearchDescription:(TPPOpenSearchDescription *)searchDescription
{
  self = [super init];
  if(!self) return nil;

  self.searchDescription = searchDescription;
  
  return self;
}

- (NSArray *)books
{
  return _books ? _books : self.feed.books;
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];

  self.collectionView.dataSource = self;
  self.collectionView.delegate = self;

  if (@available(iOS 11.0, *)) {
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  }

  self.searchActivityIndicatorView = [[UIActivityIndicatorView alloc]
                                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
  self.searchActivityIndicatorView.hidden = YES;
  [self.view addSubview:self.searchActivityIndicatorView];
  
  self.searchActivityIndicatorLabel = [[UILabel alloc] init];
  self.searchActivityIndicatorLabel.font = [UIFont palaceFontOfSize:14.0];
  self.searchActivityIndicatorLabel.text = NSLocalizedString(@"Loading... Please wait.", @"Message explaining that the download is still going");
  self.searchActivityIndicatorLabel.hidden = YES;
  [self.view addSubview:self.searchActivityIndicatorLabel];
  [self.searchActivityIndicatorLabel autoAlignAxis:ALAxisVertical toSameAxisOfView:self.searchActivityIndicatorView];
  [self.searchActivityIndicatorLabel autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.searchActivityIndicatorView withOffset:8.0];
  
  self.searchBar = [[UISearchBar alloc] init];
  self.searchBar.delegate = self;
  self.searchBar.placeholder = self.searchDescription.humanReadableDescription;
  [self.searchBar sizeToFit];
  [self.searchBar becomeFirstResponder];
  
  self.noResultsLabel = [[UILabel alloc] init];
  self.noResultsLabel.text = NSLocalizedString(@"No Results Found", nil);
  self.noResultsLabel.font = [UIFont palaceFontOfSize:17];
  [self.noResultsLabel sizeToFit];
  self.noResultsLabel.hidden = YES;
  [self.view addSubview:self.noResultsLabel];
  
  __weak TPPCatalogSearchViewController *weakSelf = self;
  self.reloadView = [[TPPReloadView alloc] init];
  self.reloadView.handler = ^{
    weakSelf.reloadView.hidden = YES;
    // |weakSelf.searchBar| will always contain the last search because the reload view is hidden as
    // soon as editing begins (and thus cannot be clicked if the search bar text has changed).
    [weakSelf searchBarSearchButtonClicked:weakSelf.searchBar];
  };
  self.reloadView.hidden = YES;
  [self.view addSubview:self.reloadView];
  
  self.navigationItem.titleView = self.searchBar;
}

- (void)viewWillLayoutSubviews
{
  [super viewWillLayoutSubviews];

  self.searchActivityIndicatorView.center = self.view.center;
  [self.searchActivityIndicatorView integralizeFrame];

  self.noResultsLabel.center = self.view.center;
  self.noResultsLabel.frame = CGRectMake(CGRectGetMinX(self.noResultsLabel.frame),
                                         CGRectGetHeight(self.view.frame) * 0.333,
                                         CGRectGetWidth(self.noResultsLabel.frame),
                                         CGRectGetHeight(self.noResultsLabel.frame));
  [self.noResultsLabel integralizeFrame];

  [self.reloadView centerInSuperview];
}

- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  UIEdgeInsets newInsets = UIEdgeInsetsMake(CGRectGetMaxY(self.facetBarView.frame),
                                            0,
                                            self.bottomLayoutGuide.length,
                                            0);
  if (!UIEdgeInsetsEqualToEdgeInsets(self.collectionView.contentInset, newInsets)) {
    self.collectionView.contentInset = newInsets;
    self.collectionView.scrollIndicatorInsets = newInsets;
  }
}

- (void)viewWillDisappear:(BOOL)animated
{
  [super viewWillDisappear:animated];
  [self.searchBar resignFirstResponder];
}

- (void)addActivityIndicatorLabel:(NSTimer*)timer
{
  if (!self.searchActivityIndicatorView.isHidden) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [UIView transitionWithView:self.searchActivityIndicatorLabel
                        duration:0.5
                         options:UIViewAnimationOptionTransitionCrossDissolve
                      animations:^{
        self.searchActivityIndicatorLabel.hidden = NO;
      } completion:nil];
    });
  }
  [timer invalidate];
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
  [self.feed prepareForBookIndex:indexPath.row];
  
  TPPBook *const book = self.books[indexPath.row];
  
  return TPPBookCellDequeue(collectionView, indexPath, book);
}

#pragma mark UICollectionViewDelegate

- (void)collectionView:(__attribute__((unused)) UICollectionView *)collectionView
didSelectItemAtIndexPath:(NSIndexPath *const)indexPath
{
  TPPBook *const book = self.books[indexPath.row];
  
  [[[TPPBookDetailViewController alloc] initWithBook:book] presentFromViewController:self];
}

#pragma mark NYPLCatalogUngroupedFeedDelegate

- (void)catalogUngroupedFeed:(__attribute__((unused))
                              TPPCatalogUngroupedFeed *)catalogUngroupedFeed
              didUpdateBooks:(__attribute__((unused)) NSArray *)books
{
  [self.collectionView reloadData];
}

- (void)catalogUngroupedFeed:(__unused TPPCatalogUngroupedFeed *)catalogUngroupedFeed
                 didAddBooks:(__unused NSArray *)books
                       range:(__unused NSRange const)range
{
  // FIXME: This is not ideal but we were having double-free issues with
  // `insertItemsAtIndexPaths:`. See issue #144 for more information.
  
  // Debounce timer reduces content flickering on each reload
  if (!self.debounceTimer) {
    self.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:NO block:^(NSTimer * _Nonnull timer) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:0]];
        self.debounceTimer = nil;
      });
    }];
  }
}

#pragma mark UISearchBarDelegate

- (void)configureUIForActiveSearchState
{
  self.collectionView.hidden = YES;
  self.noResultsLabel.hidden = YES;
  self.reloadView.hidden = YES;
  self.searchActivityIndicatorView.hidden = NO;
  [self.searchActivityIndicatorView startAnimating];

  self.searchActivityIndicatorLabel.hidden = YES;
  [NSTimer scheduledTimerWithTimeInterval: 10.0 target: self
                                 selector: @selector(addActivityIndicatorLabel:) userInfo: nil repeats: NO];

  self.searchBar.userInteractionEnabled = NO;
  self.searchBar.alpha = 0.5;
  [self.searchBar resignFirstResponder];
}

- (void)fetchUngroupedFeedFromURL:(NSURL *)URL
{
  [self.debounceTimer invalidate];
  self.debounceTimer = nil;
  [TPPCatalogUngroupedFeed
   withURL:URL
   useTokenIfAvailable:NO
   handler:^(TPPCatalogUngroupedFeed *const category) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if(category) {
        self.feed = category;
        self.feed.delegate = self;
      }
      [self updateUIAfterSearchSuccess:(category != nil)];
    });
  }];
}

- (void)searchBarSearchButtonClicked:(__attribute__((unused)) UISearchBar *)searchBar
{
  [self configureUIForActiveSearchState];
  
  if(self.searchDescription.books) {
    self.books = [self.searchDescription.books filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(TPPBook *book, __unused NSDictionary *bindings) {
      BOOL titleMatch = [book.title.lowercaseString containsString:self.searchBar.text.lowercaseString];
      BOOL authorMatch = [book.authors.lowercaseString containsString:self.searchBar.text.lowercaseString];
      return titleMatch || authorMatch;
    }]];
    [self updateUIAfterSearchSuccess:YES];
  } else {
    NSURL *searchURL = [self.searchDescription
                        OPDSURLForSearchingString:self.searchBar.text];
    [self fetchUngroupedFeedFromURL:searchURL];
  }
}

- (void)updateUIAfterSearchSuccess:(BOOL)success
{
  [self createAndConfigureFacetBarView];

  self.collectionView.alpha = 0.0;
  self.searchActivityIndicatorView.hidden = YES;
  [self.searchActivityIndicatorView stopAnimating];
  self.searchActivityIndicatorLabel.hidden = YES;
  self.searchBar.userInteractionEnabled = YES;

  if(success) {
    [self.debounceTimer invalidate];
    self.debounceTimer = nil;
    [self.collectionView scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
    [self.collectionView reloadData];
    
    if(self.books.count > 0) {
      self.collectionView.hidden = NO;
    } else {
      self.noResultsLabel.hidden = NO;
    }
  } else {
    self.reloadView.hidden = NO;
  }

  [UIView animateWithDuration:0.3 animations:^{
    self.searchBar.alpha = 1.0;
    self.facetBarView.alpha = 1.0;
    self.collectionView.alpha = 1.0;
  }];
}

- (BOOL)searchBarShouldBeginEditing:(__attribute__((unused)) UISearchBar *)searchBar
{
  self.reloadView.hidden = YES;
  
  return YES;
}

- (void)createAndConfigureFacetBarView
{
  if (self.facetBarView) {
    [self.facetBarView removeFromSuperview];
  }

  self.facetBarView = [[TPPFacetBarView alloc] initWithOrigin:CGPointZero width:self.view.bounds.size.width];
  self.facetBarView.entryPointView.delegate = self;
  self.facetBarView.entryPointView.dataSource = self;
  self.facetBarView.alpha = 0;

  [self.view addSubview:self.facetBarView];
  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeLeading];
  [self.facetBarView autoPinEdgeToSuperviewEdge:ALEdgeTrailing];
  [self.facetBarView autoPinEdgeToSuperviewMargin:ALEdgeTop];
}

#pragma mark NYPLEntryPointViewDelegate

- (void)entryPointViewDidSelectWithEntryPointFacet:(TPPCatalogFacet *)facet
{
  [self configureUIForActiveSearchState];
  NSURL *const newURL = facet.href;
  [self fetchUngroupedFeedFromURL:newURL];
}

- (NSArray<TPPCatalogFacet *> *)facetsForEntryPointView
{
  return self.feed.entryPoints;
}

@end
