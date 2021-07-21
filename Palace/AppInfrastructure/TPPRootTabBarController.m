#import "TPPCatalogNavigationController.h"
#import "TPPHoldsNavigationController.h"
#import "TPPMyBooksNavigationController.h"

#ifdef SIMPLYE
// TODO: SIMPLY-3053 this #ifdef can be removed once this ticket is done
#import "TPPSettingsSplitViewController.h"
#endif

#import "TPPRootTabBarController.h"
#import "Palace-Swift.h"

@interface TPPRootTabBarController () <UITabBarControllerDelegate>

@property (nonatomic) TPPCatalogNavigationController *catalogNavigationController;
@property (nonatomic) TPPMyBooksNavigationController *myBooksNavigationController;
@property (nonatomic) TPPHoldsNavigationController *holdsNavigationController;
@property (nonatomic) TPPSettingsSplitViewController *settingsSplitViewController;
@property (readwrite) TPPR2Owner *r2Owner;

@end

@implementation TPPRootTabBarController

+ (instancetype)sharedController
{
  static dispatch_once_t predicate;
  static TPPRootTabBarController *sharedController = nil;
  
  dispatch_once(&predicate, ^{
    sharedController = [[self alloc] init];
    if(!sharedController) {
      TPPLOG(@"Failed to create shared controller.");
    }
  });
  
  return sharedController;
}

#pragma mark NSObject

- (instancetype)init
{
  self = [super init];
  if(!self) return nil;
  
  self.delegate = self;
  
  self.catalogNavigationController = [[TPPCatalogNavigationController alloc] init];
  self.myBooksNavigationController = [[TPPMyBooksNavigationController alloc] init];
  self.holdsNavigationController = [[TPPHoldsNavigationController alloc] init];
  self.settingsSplitViewController = [[TPPSettingsSplitViewController alloc]
                                      initWithCurrentLibraryAccountProvider:
                                      AccountsManager.shared];

  [self setTabViewControllers];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(setTabViewControllers)
                                               name:NSNotification.TPPCurrentAccountDidChange
                                             object:nil];
  
  self.r2Owner = [[TPPR2Owner alloc] init];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setTabViewControllers
{
  [TPPMainThreadRun asyncIfNeeded:^{
    [self setTabViewControllersInternal];
  }];
}

- (void)setTabViewControllersInternal
{
  Account *const currentAccount = [AccountsManager shared].currentAccount;
  if (currentAccount.details.supportsReservations) {
    self.viewControllers = @[self.catalogNavigationController,
                             self.myBooksNavigationController,
                             self.holdsNavigationController,
                             self.settingsSplitViewController];
  } else {
    self.viewControllers = @[self.catalogNavigationController,
                             self.myBooksNavigationController,
                             self.settingsSplitViewController];
    [self setInitialSelectedTab];
  }
}

#pragma mark - UITabBarControllerDelegate

- (BOOL)tabBarController:(UITabBarController *)__unused tabBarController
shouldSelectViewController:(nonnull UIViewController *)viewController
{
  if ([viewController isEqual:self.settingsSplitViewController] && [self.selectedViewController isEqual:self.settingsSplitViewController]) {
    UINavigationController *navController = [[(UISplitViewController *)viewController viewControllers] firstObject];
    [navController popToRootViewControllerAnimated:YES];
  }
  return YES;
}

#pragma mark -

- (void)safelyPresentViewController:(UIViewController *)viewController
                           animated:(BOOL)animated
                         completion:(void (^)(void))completion
{
  UIViewController *baseController = self;
  
  while(baseController.presentedViewController) {
    baseController = baseController.presentedViewController;
  }
  
  [baseController presentViewController:viewController animated:animated completion:completion];
}

- (void)pushViewController:(UIViewController *const)viewController
                  animated:(BOOL const)animated
{
  if(![self.selectedViewController isKindOfClass:[UINavigationController class]]) {
    TPPLOG(@"Selected view controller is not a navigation controller.");
    return;
  }
  
  if(self.presentedViewController) {
    [self dismissViewControllerAnimated:YES completion:nil];
  }
  
  [(UINavigationController *)self.selectedViewController
   pushViewController:viewController
   animated:animated];
}

@end
