#import "TPPSettingsPrimaryNavigationController.h"
#import "TPPSettingsPrimaryTableViewController.h"
#import "TPPSettingsEULAViewController.h"
#import "TPPBook.h"
#import "TPPMyBooksDownloadCenter.h"
#import "TPPRootTabBarController.h"
#import "Palace-Swift.h"

#import "TPPSettingsSplitViewController.h"

@interface TPPSettingsSplitViewController ()
  <UISplitViewControllerDelegate, NYPLSettingsPrimaryTableViewControllerDelegate>

@property (nonatomic) TPPSettingsPrimaryNavigationController *primaryNavigationController;
@property (nonatomic) bool isFirstLoad;
@property (nonatomic) id<TPPCurrentLibraryAccountProvider> currentLibraryAccountProvider;
@end

@implementation TPPSettingsSplitViewController

#pragma mark NSObject

- (instancetype)initWithCurrentLibraryAccountProvider: (id<TPPCurrentLibraryAccountProvider>)currentAccountProvider
{
  self = [super init];
  if(!self) return nil;
  
  self.delegate = self;
  self.currentLibraryAccountProvider = currentAccountProvider;

  self.title = NSLocalizedString(@"Settings", nil);
  self.tabBarItem.image = [UIImage imageNamed:@"Settings"];
  
  self.primaryNavigationController = [[TPPSettingsPrimaryNavigationController alloc] init];
  self.primaryNavigationController.primaryTableViewController.delegate = self;
  self.viewControllers = @[self.primaryNavigationController];
  
  self.presentsWithGesture = NO;
  
  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  NSArray *accounts = [[TPPSettings sharedSettings] settingsAccountsList];
  
  if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad &&
     (self.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassCompact)) {
    
    self.viewControllers = @[self.primaryNavigationController,
                             [[UINavigationController alloc] initWithRootViewController:
                              [[TPPSettingsAccountsTableViewController alloc] initWithAccounts:accounts]]];
    
    [self highlightFirstTableViewRow:YES];
  } else {
    self.viewControllers = @[self.primaryNavigationController];
  }
  
  self.preferredDisplayMode = UISplitViewControllerDisplayModeAllVisible;
  self.isFirstLoad = YES;
}

- (void)highlightFirstTableViewRow:(bool)highlight
{
  if (highlight) {
    [self.primaryNavigationController.primaryTableViewController.tableView
     selectRowAtIndexPath:NYPLSettingsPrimaryTableViewControllerIndexPathFromSettingsItem(NYPLSettingsPrimaryTableViewControllerItemAccount)
     animated:NO
     scrollPosition:UITableViewScrollPositionMiddle];
  } else {
    [self.primaryNavigationController.primaryTableViewController.tableView
     deselectRowAtIndexPath:NYPLSettingsPrimaryTableViewControllerIndexPathFromSettingsItem(                                     NYPLSettingsPrimaryTableViewControllerItemAccount)
     animated:NO];
  }
}

#pragma mark UISplitViewControllerDelegate

- (BOOL)splitViewController:(__attribute__((unused)) UISplitViewController *)splitViewController
collapseSecondaryViewController:(__attribute__((unused)) UIViewController *)secondaryViewController
ontoPrimaryViewController:(__attribute__((unused)) UIViewController *)primaryViewController
{
  if (self.isFirstLoad) {
    self.isFirstLoad = NO;
    return YES;
  } else {
    self.isFirstLoad = NO;
    return NO;
  }
}

#pragma mark NYPLSettingsPrimaryTableViewControllerDelegate

- (void)settingsPrimaryTableViewController:(__attribute__((unused)) TPPSettingsPrimaryTableViewController *const)settingsPrimaryTableVC
                             didSelectItem:(NYPLSettingsPrimaryTableViewControllerItem const)item
{
  UIViewController *viewController;
  NSArray *accounts;
  switch(item) {
    case NYPLSettingsPrimaryTableViewControllerItemAccount:
      accounts = [[TPPSettings sharedSettings] settingsAccountsList];
      viewController = [[TPPSettingsAccountsTableViewController alloc] initWithAccounts:accounts];
      break;
    case NYPLSettingsPrimaryTableViewControllerItemAbout:
      viewController = [[RemoteHTMLViewController alloc]
                        initWithURL:[NSURL URLWithString: TPPSettings.NYPLAboutSimplyEURLString]
                        title:NSLocalizedString(@"AboutApp", nil)
                        failureMessage:NSLocalizedString(@"The page could not load due to a connection error.", nil)];
      break;
    case NYPLSettingsPrimaryTableViewControllerItemEULA:
      viewController = [[RemoteHTMLViewController alloc]
                        initWithURL:[NSURL URLWithString: TPPSettings.NYPLUserAgreementURLString]
                        title:NSLocalizedString(@"EULA", nil)
                        failureMessage:NSLocalizedString(@"The page could not load due to a connection error.", nil)];
      break;
    case NYPLSettingsPrimaryTableViewControllerItemSoftwareLicenses:
      viewController = [[BundledHTMLViewController alloc]
                        initWithFileURL:[[NSBundle mainBundle]
                                         URLForResource:@"software-licenses"
                                         withExtension:@"html"]
                        title:NSLocalizedString(@"SoftwareLicenses", nil)];
      break;
    case NYPLSettingsPrimaryTableViewControllerItemDeveloperSettings:
      viewController = [[TPPDeveloperSettingsTableViewController alloc] init];
      break;
    default:
      return;
  }
  
  [self showDetailViewController:[[UINavigationController alloc]
                                  initWithRootViewController:viewController]
                          sender:self];
}

@end
