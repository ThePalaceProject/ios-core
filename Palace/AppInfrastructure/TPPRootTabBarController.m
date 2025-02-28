#import "TPPCatalogNavigationController.h"
#import "TPPHoldsNavigationController.h"
#import "TPPRootTabBarController.h"
#import "Palace-Swift.h"

@interface TPPRootTabBarController () <UITabBarControllerDelegate>

@property (nonatomic) TPPCatalogNavigationController *catalogNavigationController;
@property (nonatomic) TPPMyBooksViewController *myBooksNavigationController;
@property (nonatomic) TPPHoldsNavigationController *holdsNavigationController;
@property (nonatomic) TPPSettingsViewController *settingsViewController;
@property (readwrite) TPPR3Owner *r3Owner;

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
  self.myBooksNavigationController = (TPPMyBooksViewController * ) [TPPMyBooksViewController makeSwiftUIViewWithDismissHandler:^{
    [[self presentedViewController] dismissViewControllerAnimated:YES completion:nil];
  }];
  self.holdsNavigationController = [[TPPHoldsNavigationController alloc] init];
  self.settingsViewController = (TPPSettingsViewController * ) [TPPSettingsViewController makeSwiftUIViewWithDismissHandler:^{
    [[self presentedViewController] dismissViewControllerAnimated:YES completion:nil];
  }];

  [self setTabViewControllers];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(setTabViewControllers)
                                               name:NSNotification.TPPCurrentAccountDidChange
                                             object:nil];
  
  self.r3Owner = [[TPPR3Owner alloc] init];
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
                             self.settingsViewController];
  } else {
    self.viewControllers = @[self.catalogNavigationController,
                             self.myBooksNavigationController,
                             self.settingsViewController];
    // Change selected index if the "Reservations" or "Settings" tab is selected
    if (self.selectedIndex > 1) {
      self.selectedIndex -= 1;
    }
  }
}

#pragma mark - UITabBarControllerDelegate

- (BOOL)tabBarController:(UITabBarController *)__unused tabBarController
shouldSelectViewController:(nonnull UIViewController *)viewController
{
  return YES;
}

#pragma mark -

- (void)safelyPresentViewController:(UIViewController *)viewController
                           animated:(BOOL)animated
                         completion:(void (^)(void))completion
{
  // Ensure we are on the main thread
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self.presentedViewController) { // Avoid infinite loop
        [self safelyPresentViewController:viewController animated:animated completion:completion];
      }
    });
    return;
  }

  UIViewController *baseController = self;

  // Traverse up only if `presentedViewController` is fully presented
  while (baseController.presentedViewController && !baseController.presentedViewController.isBeingDismissed) {
    baseController = baseController.presentedViewController;
  }

  // Ensure it's safe to present a new VC
  if (!baseController.presentedViewController) {
    [baseController presentViewController:viewController animated:animated completion:completion];
  }
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
