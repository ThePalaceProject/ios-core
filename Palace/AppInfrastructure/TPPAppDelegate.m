@import NYPLAudiobookToolkit;

#import "Palace-Swift.h"

#import "TPPConfiguration.h"
#import "TPPReachability.h"
#import "TPPRootTabBarController.h"


#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#import "TPPAccountSignInViewController.h"
#endif

// TODO: Remove these imports and move handling the "open a book url" code to a more appropriate handler
#import "TPPXML.h"
#import "TPPOPDSEntry.h"
#import "TPPBookDetailViewController.h"
#import "NSURL+NYPLURLAdditions.h"

#import "TPPAppDelegate.h"

@interface TPPAppDelegate()

@property (nonatomic) AudiobookLifecycleManager *audiobookLifecycleManager;
@property (nonatomic) TPPReachability *reachabilityManager;
@property (nonatomic) TPPUserNotifications *notificationsManager;
@property (nonatomic, readwrite) BOOL isSigningIn;
@end

@implementation TPPAppDelegate

const NSTimeInterval MinimumBackgroundFetchInterval = 60 * 60 * 24;

#pragma mark UIApplicationDelegate

- (BOOL)application:(UIApplication *)app
didFinishLaunchingWithOptions:(__attribute__((unused)) NSDictionary *)launchOptions
{
  [TPPErrorLogger configureCrashAnalytics];

  // Perform data migrations as early as possible before anything has a chance to access them
  [TPPKeychainManager validateKeychain];
  [TPPMigrationManager migrate];
  
  self.audiobookLifecycleManager = [[AudiobookLifecycleManager alloc] init];
  [self.audiobookLifecycleManager didFinishLaunching];

  [TransifexManager setup];
  [app setMinimumBackgroundFetchInterval:MinimumBackgroundFetchInterval];

  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(signingIn:)
                                             name:NSNotification.TPPIsSigningIn
                                           object:nil];

  [[NetworkQueue shared] addObserverForOfflineQueue];
  self.reachabilityManager = [TPPReachability sharedReachability];
  
  // Enable new reachability notifications
  [Reachability.shared startMonitoring];
  
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.tintColor = [TPPConfiguration mainColor];
  self.window.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
  [self.window makeKeyAndVisible];
  
  [[UITabBar appearance] setTintColor: [TPPConfiguration iconColor]];
  [[UITabBar appearance] setBackgroundColor:[TPPConfiguration backgroundColor]];
  [[UITabBarItem appearance] setTitleTextAttributes:@{NSFontAttributeName: [UIFont palaceFontOfSize:12.0]} forState:UIControlStateNormal];

  [[UINavigationBar appearance] setTintColor: [TPPConfiguration iconColor]];
  [[UINavigationBar appearance] setStandardAppearance:[TPPConfiguration defaultAppearance]];
  [[UINavigationBar appearance] setScrollEdgeAppearance:[TPPConfiguration defaultAppearance]];
  [[UINavigationBar appearance] setCompactAppearance:[TPPConfiguration defaultAppearance]];
  if (@available(iOS 15.0, *)) {
    [[UINavigationBar appearance] setCompactScrollEdgeAppearance:[TPPConfiguration defaultAppearance]];
  }
  
  [self setUpRootVC];

  [TPPErrorLogger logNewAppLaunch];

  // Initialize TPPBookRegistry
  [TPPBookRegistry shared];
  
  // Push Notificatoins
  // TODO: Enable push notifications when CM starts supporting them
//  [[NotificationService sharedService] setupPushNotifications];

  return YES;
}

// note: this appears to always be called on main thread while app is on background
- (void)application:(__attribute__((unused)) UIApplication *)application
performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))backgroundFetchHandler
{
  NSDate *startDate = [NSDate date];
  if ([TPPUserNotifications backgroundFetchIsNeeded]) {
    TPPLOG_F(@"[Background Fetch] Starting book registry sync. "
                  "ElapsedTime=%f", -startDate.timeIntervalSinceNow);
    [TPPBookRegistry.shared syncWithCompletion:^(NSDictionary *errorDocument, BOOL newBooks) {
      NSString *result;
      if (errorDocument) {
        result = @"error document";
        backgroundFetchHandler(UIBackgroundFetchResultFailed);
      } else if (newBooks) {
        result = @"new ready books available";
        backgroundFetchHandler(UIBackgroundFetchResultNewData);
      } else {
        result = @"no ready books fetched";
        backgroundFetchHandler(UIBackgroundFetchResultNoData);
      }
      TPPLOG_F(@"[Background Fetch] Completed with %@."
               "ElapsedTime=%f", result, -startDate.timeIntervalSinceNow);
    }];
  } else {
    backgroundFetchHandler(UIBackgroundFetchResultNoData);
  }
}

- (BOOL)application:(UIApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> * _Nullable))restorationHandler
{
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] && [userActivity.webpageURL.host isEqualToString:TPPSettings.shared.universalLinksURL.host]) {
        [[NSNotificationCenter defaultCenter]
         postNotificationName:NSNotification.TPPAppDelegateDidReceiveCleverRedirectURL
         object:userActivity.webpageURL];

        return YES;
    }

    return NO;
}

- (BOOL)application:(__unused UIApplication *)app
            openURL:(NSURL *)url
            options:(__unused NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
  if ([self shouldHandleAppSpecificCustomURLSchemesForURL:url]) {
    return YES;
  }

  // URLs should be a permalink to a feed URL
  NSURL *entryURL = [url URLBySwappingForScheme:@"http"];
  NSData *data = [NSData dataWithContentsOfURL:entryURL];
  TPPXML *xml = [TPPXML XMLWithData:data];
  TPPOPDSEntry *entry = [[TPPOPDSEntry alloc] initWithXML:xml];
  
  TPPBook *book = [[TPPBook alloc] initWithEntry:entry];
  if (!book) {
    NSString *alertTitle = @"Error Opening Link";
    NSString *alertMessage = @"There was an error opening the linked book.";
    UIAlertController *alert = [TPPAlertUtils alertWithTitle:alertTitle message:alertMessage];
    [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
    TPPLOG(@"Failed to create book from deep-linked URL.");
    return NO;
  }
  
  TPPBookDetailViewController *bookDetailVC = [[TPPBookDetailViewController alloc] initWithBook:book];
  TPPRootTabBarController *tbc = (TPPRootTabBarController *) self.window.rootViewController;

  if (!tbc || ![tbc.selectedViewController isKindOfClass:[UINavigationController class]]) {
    TPPLOG(@"Casted views were not of expected types.");
    return NO;
  }

  [tbc setSelectedIndex:0];

  UINavigationController *navFormSheet = (UINavigationController *) tbc.selectedViewController.presentedViewController;
  if (tbc.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact) {
    [tbc.selectedViewController pushViewController:bookDetailVC animated:YES];
  } else if (navFormSheet) {
    [navFormSheet pushViewController:bookDetailVC animated:YES];
  } else {
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:bookDetailVC];
    navVC.modalPresentationStyle = UIModalPresentationFormSheet;
    [tbc.selectedViewController presentViewController:navVC animated:YES completion:nil];
  }

  return YES;
}

-(void)applicationDidBecomeActive:(__unused UIApplication *)app
{
  [TPPErrorLogger setUserID:[[TPPUserAccount sharedAccount] barcode]];
  [self completeBecomingActive];
  
#if FEATURE_DRM_CONNECTOR
  // If Adobe DRM cerificate expired, the app shows this alert when the user opens the app.
  // We don't show this alert if the user is going to see Welcome screen,
  // because we need to show modal views there as well
  if ([AdobeCertificate.defaultCertificate hasExpired] == YES &&
      AdobeCertificate.shouldNotifyAboutExpiration &&
      [[TPPSettings shared] userHasSeenWelcomeScreen]
      ) {
    [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:[TPPAlertUtils expiredAdobeDRMAlert] viewController:nil animated:YES completion:nil];
  }
#endif
}

- (void)applicationWillResignActive:(__attribute__((unused)) UIApplication *)application
{

}

- (void)applicationWillTerminate:(__unused UIApplication *)application
{
  [self.audiobookLifecycleManager willTerminate];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)application:(__unused UIApplication *)application
handleEventsForBackgroundURLSession:(NSString *const)identifier
completionHandler:(void (^const)(void))completionHandler
{
  [self.audiobookLifecycleManager
   handleEventsForBackgroundURLSessionFor:identifier
   completionHandler:completionHandler];
}

#pragma mark -

- (void)signingIn:(NSNotification *)notif
{
  self.isSigningIn = [notif.object boolValue];
}

@end
