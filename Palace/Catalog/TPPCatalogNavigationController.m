#import "Palace-Swift.h"
#import "TPPCatalogFeedViewController.h"
#import "TPPConfiguration.h"
#import "TPPCatalogNavigationController.h"
#import "TPPAccountSignInViewController.h"
#import "TPPRootTabBarController.h"
#import "NSString+TPPStringAdditions.h"

@interface TPPCatalogNavigationController()

@property (nonatomic) TPPCatalogFeedViewController *const viewController;

@end


@implementation TPPCatalogNavigationController

/// Replaces the current view controllers on the navigation stack with a single
/// view controller pointed at the current catalog URL.
- (void)loadTopLevelCatalogViewController
{
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self loadTopLevelCatalogViewControllerInternal];
    });
  } else {
    [self loadTopLevelCatalogViewControllerInternal];
  }
}

- (void)loadTopLevelCatalogViewControllerInternal
{
  // TODO: SIMPLY-2862
  // unfortunately it is possible to get here with a nil feed URL. This is
  // the result of an early initialization of the navigation controller
  // while the account is not yet set up. While this is definitely not
  // ideal, in my observations this seems to always be followed by
  // another `load` command once the authentication document is received.
  NSURL *urlToLoad = [TPPSettings sharedSettings].accountMainFeedURL;
  TPPLOG_F(@"urlToLoad for NYPLCatalogFeedViewController: %@", urlToLoad);
  self.viewController = [[TPPCatalogFeedViewController alloc]
                         initWithURL:urlToLoad];
  
  self.viewController.title = NSLocalizedString(@"Catalog", nil);

#ifdef SIMPLYE
  [self setNavigationLeftBarButtonForVC:self.viewController];
#endif

  self.viewController.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Catalog", nil) style:UIBarButtonItemStylePlain target:nil action:nil];

  self.viewControllers = @[self.viewController];
}

#pragma mark NSObject

- (instancetype)init
{
  self = [super init];
  
  self.tabBarItem.title = NSLocalizedString(@"Catalog", nil);
  self.tabBarItem.image = [UIImage imageNamed:@"Catalog"];
  self.navigationItem.title = NSLocalizedString(@"Catalog", nil);
  
  [self loadTopLevelCatalogViewController];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(currentAccountChanged) name:NSNotification.TPPCurrentAccountDidChange object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncBegan) name:NSNotification.TPPSyncBegan object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(syncEnded) name:NSNotification.TPPSyncEnded object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didSignOut) name:NSNotification.TPPDidSignOut object:nil];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)currentAccountChanged
{
  [self loadTopLevelCatalogViewController];
}

- (void)syncBegan
{
  self.navigationItem.leftBarButtonItem.enabled = NO;
  self.viewController.navigationItem.leftBarButtonItem.enabled = NO;
}

- (void)syncEnded
{
  self.navigationItem.leftBarButtonItem.enabled = YES;
  self.viewController.navigationItem.leftBarButtonItem.enabled = YES;
}

#ifdef SIMPLYE
- (void)updateCatalogFeedSettingCurrentAccount:(Account *)account
{
  [account loadAuthenticationDocumentUsingSignedInStateProvider:nil completion:^(BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (success) {
        [AccountsManager sharedInstance].currentAccount = account;
        [self updateFeedAndRegistryOnAccountChange];
      } else {
        NSString *title = NSLocalizedString(@"Error Loading Library", @"Title for alert related to error loading library authentication doc");
        NSString *msg = NSLocalizedString(@"We can’t get your library right now. Please close and reopen the app to try again.", @"Message for alert related to error loading library authentication doc");
        UIAlertController *alert = [TPPAlertUtils
                                    alertWithTitle:title
                                    message:msg];
        [self presentViewController:alert
                           animated:YES
                         completion:nil];
      }
    });
  }];
}
#endif

- (void)updateFeedAndRegistryOnAccountChange
{
  Account *account = [[AccountsManager sharedInstance] currentAccount];
  __block NSURL *mainFeedUrl = [NSURL URLWithString:account.catalogUrl];

  void (^completion)(void) = ^() {
    [[TPPSettings sharedSettings] setAccountMainFeedURL:mainFeedUrl];
    [UIApplication sharedApplication].delegate.window.tintColor = [TPPConfiguration mainColor];
    
    [[NSNotificationCenter defaultCenter]
     postNotificationName:NSNotification.TPPCurrentAccountDidChange
     object:nil];
  };

  TPPUserAccount * const user = TPPUserAccount.sharedAccount;
  if (user.authDefinition.needsAgeCheck) {
    [[[AccountsManager sharedInstance] ageCheck] verifyCurrentAccountAgeRequirementWithUserAccountProvider:[TPPUserAccount sharedAccount]
                                                                     currentLibraryAccountProvider:[AccountsManager sharedInstance]
                                                                                        completion:^(BOOL isOfAge)  {
      [TPPMainThreadRun asyncIfNeeded: ^{
        mainFeedUrl = [user.authDefinition coppaURLWithIsOfAge:isOfAge];
        completion();
      }];
    }];
  } else if (user.catalogRequiresAuthentication && !user.hasCredentials) {
    // we're signed out, so sign in
    [TPPAccountSignInViewController requestCredentialsWithCompletion:^{
      [TPPMainThreadRun asyncIfNeeded:completion];
    }];
  } else {
    [TPPMainThreadRun asyncIfNeeded:completion];
  }
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  TPPSettings *settings = [TPPSettings sharedSettings];
  if (settings.userHasSeenWelcomeScreen) {
    Account *account = [[AccountsManager sharedInstance] currentAccount];

    __block NSURL *mainFeedUrl = [NSURL URLWithString:account.catalogUrl];
    void (^completion)(void) = ^() {
      [[TPPSettings sharedSettings] setAccountMainFeedURL:mainFeedUrl];
      [UIApplication sharedApplication].delegate.window.tintColor = [TPPConfiguration mainColor];
      // TODO: SIMPLY-2862 should this be posted only if actually different?
      [[NSNotificationCenter defaultCenter]
      postNotificationName:NSNotification.TPPCurrentAccountDidChange
      object:nil];
    };

    if (TPPUserAccount.sharedAccount.authDefinition.needsAgeCheck) {
      [[[AccountsManager sharedInstance] ageCheck] verifyCurrentAccountAgeRequirementWithUserAccountProvider:[TPPUserAccount sharedAccount]
                                                                       currentLibraryAccountProvider:[AccountsManager sharedInstance]
                                                                                          completion:^(BOOL isOfAge) {
        dispatch_async(dispatch_get_main_queue(), ^{
          mainFeedUrl = [TPPUserAccount.sharedAccount.authDefinition coppaURLWithIsOfAge:isOfAge];
          completion();
        });
      }];
    } else {
      completion();
    }
  }
}

- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  
  if (UIAccessibilityIsVoiceOverRunning()) {
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
  }

  TPPSettings *settings = [TPPSettings sharedSettings];
  
  if (!settings.userHasSeenWelcomeScreen  || TPPConfiguration.registryChanged) {
    Account *currentAccount = [[AccountsManager sharedInstance] currentAccount];

    __block NSURL *mainFeedUrl = [NSURL URLWithString:currentAccount.catalogUrl];
    void (^completion)(void) = ^() {
      [[TPPSettings sharedSettings] setAccountMainFeedURL:mainFeedUrl];
      [UIApplication sharedApplication].delegate.window.tintColor = [TPPConfiguration mainColor];
      
      TPPWelcomeScreenViewController *welcomeScreenVC = [[TPPWelcomeScreenViewController alloc] initWithCompletion:^(Account *const account) {
        if (![NSThread isMainThread]) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self welcomeScreenCompletionHandlerForAccount:account];
          });
        } else {
          [self welcomeScreenCompletionHandlerForAccount:account];
        }
      }];

      // Update current registry hash if registry changed
      if (TPPConfiguration.registryChanged) {
        [TPPConfiguration updateSavedeRegistryKey];
      }

      UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:welcomeScreenVC];

      [navController setModalPresentationStyle:UIModalPresentationFullScreen];
      [navController setModalTransitionStyle:UIModalTransitionStyleCrossDissolve];

      TPPRootTabBarController *vc = [TPPRootTabBarController sharedController];
      [vc safelyPresentViewController:navController animated:YES completion:nil];

      // Present onboarding screens above the welcome screen.
      UIViewController *onboardingVC = [TPPOnboardingViewController makeSwiftUIViewWithDismissHandler:^{
        [[self presentedViewController] dismissViewControllerAnimated:YES completion:^{
#ifdef FEATURE_DRM_CONNECTOR
          if ([AdobeCertificate.defaultCertificate hasExpired] == YES) {
            [vc safelyPresentViewController:[TPPAlertUtils expiredAdobeDRMAlert] animated:YES completion:nil];
          }
#endif
        }];
      }];
      [vc safelyPresentViewController:onboardingVC animated:YES completion:nil];
    };
    if (TPPUserAccount.sharedAccount.authDefinition.needsAgeCheck) {
      [[[AccountsManager sharedInstance] ageCheck] verifyCurrentAccountAgeRequirementWithUserAccountProvider:[TPPUserAccount sharedAccount]
                                                                       currentLibraryAccountProvider:[AccountsManager sharedInstance]
                                                                                          completion:^(BOOL isOfAge) {
        mainFeedUrl = [TPPUserAccount.sharedAccount.authDefinition coppaURLWithIsOfAge:isOfAge];
        completion();
      }];
    } else {
      completion();
    }
  }
}

- (void)welcomeScreenCompletionHandlerForAccount:(Account *const)account
{
  [[TPPSettings sharedSettings] setUserHasSeenWelcomeScreen:YES];
  [AccountsManager sharedInstance].currentAccount = account;
  [self updateFeedAndRegistryOnAccountChange];
  [self dismissViewControllerAnimated:YES completion:nil];
}

@end
