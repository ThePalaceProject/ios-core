@import NYPLAudiobookToolkit;

#import "Palace-Swift.h"

#import "TPPConfiguration.h"
#import "TPPBookRegistry.h"
#import "TPPReachability.h"
#import "TPPReaderSettings.h"
#import "TPPRootTabBarController.h"


#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#import "TPPAccountSignInViewController.h"
#endif

// TODO: Remove these imports and move handling the "open a book url" code to a more appropriate handler
#import "TPPXML.h"
#import "TPPOPDSEntry.h"
#import "TPPBook.h"
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

  [app setMinimumBackgroundFetchInterval:MinimumBackgroundFetchInterval];

  self.notificationsManager = [[TPPUserNotifications alloc] init];
  [self.notificationsManager authorizeIfNeeded];
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(signingIn:)
                                             name:NSNotification.TPPIsSigningIn
                                           object:nil];

  [[NetworkQueue shared] addObserverForOfflineQueue];
  self.reachabilityManager = [TPPReachability sharedReachability];
  
  self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
  self.window.tintColor = [TPPConfiguration mainColor];
  self.window.tintAdjustmentMode = UIViewTintAdjustmentModeNormal;
  [self.window makeKeyAndVisible];
  
  [[UITabBar appearance] setTintColor: [TPPConfiguration iconColor]];
  [[UINavigationBar appearance] setTintColor: [TPPConfiguration iconColor]];
  
  [self setUpRootVC];

  [TPPErrorLogger logNewAppLaunch];

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
    // Only the "current library" account syncs during a background fetch.
    [[TPPBookRegistry sharedRegistry] syncResettingCache:NO completionHandler:^(NSDictionary *errorDict) {
      if (errorDict == nil) {
        [[TPPBookRegistry sharedRegistry] save];
      }
    } backgroundFetchHandler:^(UIBackgroundFetchResult result) {
      TPPLOG_F(@"[Background Fetch] Completed with result %lu. "
                "ElapsedTime=%f", (unsigned long)result, -startDate.timeIntervalSinceNow);
      backgroundFetchHandler(result);
    }];
  } else {
    TPPLOG_F(@"[Background Fetch] Registry sync not needed. "
              "ElapsedTime=%f", -startDate.timeIntervalSinceNow);
    backgroundFetchHandler(UIBackgroundFetchResultNewData);
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
  
  TPPBook *book = [TPPBook bookWithEntry:entry];
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
  if ([AdobeCertificate.defaultCertificate hasExpired] == YES && AdobeCertificate.shouldNotifyAboutExpiration) {
    UIAlertController *alert = [TPPAlertUtils
                                alertWithTitle:NSLocalizedString(@"Something went wrong with the Adobe DRM system", @"Expired DRM certificate title")
                                message:NSLocalizedString(@"Some books will be unavailable in this version. Please try updating to the latest version of the application.", @"Expired DRM certificate message")
                                ];
    [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert viewController:nil animated:YES completion:nil];
  }
#endif
}

- (void)applicationWillResignActive:(__attribute__((unused)) UIApplication *)application
{
  [[TPPBookRegistry sharedRegistry] save];
  [[TPPReaderSettings sharedSettings] save];
}

- (void)applicationWillTerminate:(__unused UIApplication *)application
{
  [self.audiobookLifecycleManager willTerminate];
  [[TPPBookRegistry sharedRegistry] save];
  [[TPPReaderSettings sharedSettings] save];
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
