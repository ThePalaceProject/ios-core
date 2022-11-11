
#import "TPPBookDetailView.h"
#import "TPPCatalogFeedViewController.h"
#import "TPPCatalogLane.h"
#import "TPPCatalogLaneCell.h"
#import "TPPMyBooksDownloadCenter.h"
#import "TPPMyBooksDownloadInfo.h"
#import "TPPRootTabBarController.h"
#import "TPPSession.h"
#import "TPPProblemReportViewController.h"
#import "NSURLRequest+NYPLURLRequestAdditions.h"
#import <PureLayout/PureLayout.h>

#import "TPPBookDetailViewController.h"

@interface TPPBookDetailViewController () <TPPBookDetailViewDelegate, TPPProblemReportViewControllerDelegate, TPPCatalogLaneCellDelegate, UIAdaptivePresentationControllerDelegate>

@property (nonatomic) TPPBook *book;
@property (nonatomic) TPPBookDetailView *bookDetailView;
@property (nonatomic) TPPNetworkExecutor *executor;

-(void)didCacheProblemDocument;

@end

@implementation TPPBookDetailViewController

- (instancetype)initWithBook:(TPPBook *const)book
{
  self = [super initWithNibName:nil bundle:nil];
  if(!self) return nil;
  
  if(!book) {
    @throw NSInvalidArgumentException;
  }

  self.book = book;
    
  self.executor = [[TPPNetworkExecutor alloc]
                   initWithCredentialsProvider:nil
                   cachingStrategy:NYPLCachingStrategyEphemeral
                   delegateQueue:nil];

  self.title = book.title;
  UILabel *label = [[UILabel alloc] init];
  self.navigationItem.titleView = label;
  self.bookDetailView = [[TPPBookDetailView alloc] initWithBook:self.book
                                                        delegate:self];
  self.bookDetailView.state = [[TPPBookRegistry shared]
                               stateFor:self.book.identifier];

  if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
     [[TPPRootTabBarController sharedController] traitCollection].horizontalSizeClass != UIUserInterfaceSizeClassCompact) {
    self.modalPresentationStyle = UIModalPresentationFormSheet;
  }

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(bookRegistryDidChange)
                                               name:NSNotification.TPPBookRegistryDidChange
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(myBooksDidChange)
                                               name:NSNotification.TPPMyBooksDownloadCenterDidChange
                                             object:nil];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(didChangePreferredContentSize)
                                               name:UIContentSizeCategoryDidChangeNotification
                                             object:nil];
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(didCacheProblemDocument)
                                               name:NSNotification.TPPProblemDocumentWasCached
                                             object:nil];

  return self;
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  [self.view addSubview:self.bookDetailView];
  [self.bookDetailView autoPinEdgesToSuperviewEdges];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  if(self.presentingViewController.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular &&
     self.navigationController.viewControllers.count <= 1) {
    self.navigationController.navigationBarHidden = YES;
  } else {
    self.navigationController.navigationBarHidden = NO;
  }
  
  [self.bookDetailView setState:[[TPPBookRegistry shared]
                                 stateFor:self.book.identifier]];
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  if (self.bookDetailView.summaryTextView.frame.size.height < SummaryTextAbbreviatedHeight) {
    self.bookDetailView.readMoreLabel.hidden = YES;
  } else {
    self.bookDetailView.readMoreLabel.alpha = 0.0;
    self.bookDetailView.readMoreLabel.hidden = NO;
    [UIView animateWithDuration:0.3 animations:^{
      self.bookDetailView.readMoreLabel.alpha = 1.0;
    } completion:^(__unused BOOL finished) {
      self.bookDetailView.readMoreLabel.alpha = 1.0;
    }];
  }
}

#pragma mark NSObject

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark TPPBookDetailViewDelegate

- (void)didSelectCloseButton:(__attribute__((unused)) TPPBookDetailView *)detailView
{
  [NSNotificationCenter.defaultCenter
   postNotificationName:NSNotification.TPPBookDetailDidClose
   object:self.book];

  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)didSelectCancelDownloadFailedForBookDetailView:
(__attribute__((unused)) TPPBookDetailView *)detailView
{
  [[TPPMyBooksDownloadCenter sharedDownloadCenter]
   cancelDownloadForBookIdentifier:self.book.identifier];
}
  
- (void)didSelectCancelDownloadingForBookDetailView:
(__attribute__((unused)) TPPBookDetailView *)detailView
{
  [[TPPMyBooksDownloadCenter sharedDownloadCenter]
   cancelDownloadForBookIdentifier:self.book.identifier];
}

#pragma mark - TPPCatalogLaneCellDelegate

- (void)catalogLaneCell:(TPPCatalogLaneCell *)cell
     didSelectBookIndex:(NSUInteger)bookIndex
{
  TPPCatalogLane *const lane = self.bookDetailView.tableViewDelegate.catalogLanes[cell.laneIndex];
  TPPBook *const feedBook = lane.books[bookIndex];
  TPPBook *const localBook = [[TPPBookRegistry shared] bookForIdentifier:feedBook.identifier];
  TPPBook *const book = (localBook != nil) ? localBook : feedBook;
  [[[TPPBookDetailViewController alloc] initWithBook:book] presentFromViewController:self];
}

#pragma mark - ProblemReportViewControllerDelegate

-(void)didSelectReportProblemForBook:(TPPBook *)book sender:(id)sender
{
  TPPProblemReportViewController *problemVC = [[TPPProblemReportViewController alloc] initWithNibName:@"TPPProblemReportViewController" bundle:nil];
  BOOL isIPad = self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular;
  problemVC.modalPresentationStyle = isIPad ? UIModalPresentationPopover : UIModalPresentationOverCurrentContext;
  problemVC.popoverPresentationController.sourceView = sender;
  problemVC.popoverPresentationController.sourceRect = ((UIView *)sender).bounds;
  problemVC.book = book;
  problemVC.delegate = self;
  UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:problemVC];
  if(self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
    navController.modalPresentationStyle = UIModalPresentationFormSheet;
  }
  [self.navigationController pushViewController:problemVC animated:YES];
}

- (void)didSelectMoreBooksForLane:(TPPCatalogLane *)lane
{
  NSURL *urlToLoad = lane.subsectionURL;
  if (urlToLoad == nil) {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                              summary:@"Lane has no subsection URL to display more books"
                             metadata:@{
                               @"methodName": @"didSelectMoreBooksForLane:",
                               @"lane": lane.title ?: @"N/A"
                             }];
  }

  UIViewController *const viewController = [[TPPCatalogFeedViewController alloc]
                                            initWithURL:urlToLoad];
  viewController.title = lane.title;
  [self.navigationController pushViewController:viewController animated:YES];
}

- (void)problemReportViewController:(TPPProblemReportViewController *)problemReportViewController didSelectProblemWithType:(NSString *)type
{
  NSURL *reportURL = problemReportViewController.book.reportURL;
  if (reportURL) {
    NSURLRequest *request = [NSURLRequest
                             postRequestWithProblemDocument:@{@"type":type}
                             url:reportURL];
    
    [self.executor POST:request completion:nil];
  }
  if (problemReportViewController.navigationController) {
    [problemReportViewController.navigationController popViewControllerAnimated:YES];
  } else {
    [problemReportViewController dismissViewControllerAnimated:YES completion:nil];
  }
}

#pragma mark -

- (void)didChangePreferredContentSize
{
  [self.bookDetailView updateFonts];
}

// HACK ALERT: in the current usage in the app, this method MUST present
// the `viewController` synchronously!
- (void)presentFromViewController:(UIViewController *)viewController{
  NSUInteger index = [[TPPRootTabBarController sharedController] selectedIndex];

  UIViewController *currentVCTab = [[[TPPRootTabBarController sharedController] viewControllers] objectAtIndex:index];
  // If a VC is already presented as a form sheet (iPad), we push the next one
  // so the user can navigate through multiple book details without "stacking" them.
  if((UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone ||
      viewController.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact) ||
     currentVCTab.presentedViewController != nil)
  {
    [viewController.navigationController pushViewController:self animated:YES];
  } else {
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:self];
    navVC.modalPresentationStyle = UIModalPresentationFormSheet;
    [viewController presentViewController:navVC animated:YES completion:nil];
  }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraits
{
  [super traitCollectionDidChange:previousTraits];

  // Note: this is kind of an encapsulation-breaking hack. It's related
  // to the logic to change on the fly how we present the book detail page
  // in split screen mode in presentFromViewController: and
  // TPPCatalogGroupedFeedViewController::traitCollectionDidChange:.
  if (previousTraits.horizontalSizeClass == UIUserInterfaceSizeClassCompact &&
      self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
    [self.navigationController popToRootViewControllerAnimated:NO];
  }
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)__unused controller
                                                               traitCollection:(UITraitCollection *)traitCollection
{
  if (traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular) {
    return UIModalPresentationFormSheet;
  } else {
    return UIModalPresentationNone;
  }
}

-(void)didCacheProblemDocument {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.bookDetailView.tableViewDelegate configureViewIssuesCell];
      [self.bookDetailView.footerTableView reloadData];
      [self.bookDetailView.footerTableView invalidateIntrinsicContentSize];
    });
  } else {
    [self.bookDetailView.tableViewDelegate configureViewIssuesCell];
    [self.bookDetailView.footerTableView reloadData];
    [self.bookDetailView.footerTableView invalidateIntrinsicContentSize];
  }
}

- (void)didSelectViewIssuesForBook:(TPPBook *)book sender:(id)__unused sender {
  TPPProblemDocument* pDoc = [[TPPProblemDocumentCacheManager sharedInstance] getLastCachedDoc:book.identifier];
  if (pDoc) {
    TPPBookDetailsProblemDocumentViewController* vc = [[TPPBookDetailsProblemDocumentViewController alloc] initWithProblemDocument:pDoc book:book];
    UINavigationController* navVC = [self navigationController];
    if (navVC) {
      [navVC pushViewController:vc animated:YES];
    }
  }
}

- (void)myBooksDidChange
{
  [TPPMainThreadRun asyncIfNeeded:^{
    __auto_type myBooks = [TPPMyBooksDownloadCenter sharedDownloadCenter];
    __auto_type bookID = self.book.identifier;
    TPPMyBooksDownloadRightsManagement rights = [myBooks downloadInfoForBookIdentifier:bookID].rightsManagement;
    self.bookDetailView.downloadProgress = [myBooks downloadProgressForBookIdentifier:bookID];
    self.bookDetailView.downloadStarted = (rights != TPPMyBooksDownloadRightsManagementUnknown);
  }];
}

- (void)bookRegistryDidChange
{
  [TPPMainThreadRun asyncIfNeeded:^{
    TPPBookRegistry *registry = [TPPBookRegistry shared];
    TPPBook *newBook = [registry bookForIdentifier:self.book.identifier];
    if(newBook) {
      self.book = newBook;
      self.bookDetailView.book = newBook;
    }
    self.bookDetailView.state = [registry stateFor:self.book.identifier];
  }];
}

@end
