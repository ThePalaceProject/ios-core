
#import "TPPConfiguration.h"
#import "TPPReloadView.h"
#import "TPPRemoteViewController.h"

#import "NSString+TPPStringAdditions.h"
#import "UIView+TPPViewAdditions.h"
#import "Palace-Swift.h"

@import PureLayout;

@interface TPPRemoteViewController () <NSURLConnectionDataDelegate>

@property (nonatomic) UIActivityIndicatorView *activityIndicatorView;
@property (nonatomic) UILabel *activityIndicatorLabel;
@property (nonatomic) TPPReloadView *reloadView;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic, copy) UIViewController *(^handler)(TPPRemoteViewController *remoteViewController, NSData *data, NSURLResponse *response);
@property (atomic, readwrite) NSURL *URL;
@property BOOL needsReauthentication;
@property NSURLRequestCachePolicy cachePolicy;

@end

@implementation TPPRemoteViewController

- (instancetype)initWithURL:(NSURL *const)URL
                    handler:(UIViewController *(^ const)
                             (TPPRemoteViewController *remoteViewController,
                              NSData *data,
                              NSURLResponse *response))handler
{
  self = [super initWithNibName:nil bundle:nil];
  if(!self) return nil;
  
  if(!handler) {
    @throw NSInvalidArgumentException;
  }
  
  self.handler = handler;
  self.URL = URL;
  self.cachePolicy = NSURLRequestUseProtocolCachePolicy;
  
  return self;
}

- (void)showReloadViewWithMessage:(NSString*)message
{
  if (message != nil && ![message isEmptyNoWhitespace]) {
    [self.reloadView setMessage:message];
  } else {
    [self.reloadView setDefaultMessage];
  }

  self.reloadView.hidden = NO;
  self.activityIndicatorLabel.hidden = YES;
  [self.activityIndicatorView stopAnimating];
}

- (void)loadWithURL:(NSURL* _Nonnull)url
{
  TPPLOG_F(@"url=%@", url);
  self.URL = url;
  [self load];
}

- (void)load {
  self.reloadView.hidden = YES;

  [self removeAllChildViewControllers];

  if (self.dataTask) {
    [self.dataTask cancel];
    self.dataTask = nil;
  }

  if (!self.URL) {
    [self handleMissingURL];
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [self.activityIndicatorView startAnimating];
  });

  NSTimeInterval timeoutInterval = 30.0;
  NSURLRequest *request = [NSURLRequest requestWithURL:self.URL
                                           cachePolicy:self.cachePolicy
                                       timeoutInterval:timeoutInterval];

  TPPLOG_F(@"RemoteVC: Issuing request [%@]", [request loggableString]);

  self.dataTask = [TPPNetworkExecutor.shared addBearerAndExecute:request
                                                      completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

    dispatch_async(dispatch_get_main_queue(), ^{
      [self.activityIndicatorView stopAnimating];

      if (error || ![(NSHTTPURLResponse *)response isSuccess]) {
        [self handleNetworkError:error response:response data:data];
        return;
      }

      [self handleLoadedData:data response:response];
    });
  }];
}

#pragma mark - Helper Methods

/// ✅ Efficiently remove all child view controllers
- (void)removeAllChildViewControllers {
  for (UIViewController *childVC in self.childViewControllers) {
    [childVC willMoveToParentViewController:nil];
    [childVC.view removeFromSuperview];
    [childVC removeFromParentViewController];
  }
}

/// ✅ Handle missing URL case efficiently
- (void)handleMissingURL {
  dispatch_async(dispatch_get_main_queue(), ^{
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                             summary:@"RemoteViewController: Prevented load with no URL"
                            metadata:@{@"ChildVCs": self.childViewControllers}];

    [self reloadAccountsAndAuthenticationDocument];
    self.cachePolicy = NSURLRequestReloadIgnoringCacheData;
  });
}

/// ✅ Improved error handling with proper user feedback
- (void)handleNetworkError:(NSError * _Nullable)error response:(NSURLResponse * _Nullable)response data:(NSData * _Nullable)data {
  TPPProblemDocument *problemDoc = [TPPProblemDocument fromResponseError:error responseData:data];

  [self showReloadViewWithMessage:[self messageFromProblemDocument:problemDoc error:error]];

  [TPPErrorLogger logError:error
                   summary:@"RemoteViewController server-side load error"
                  metadata:@{
    @"remoteVC.URL": self.URL ?: @"none",
    @"connection.currentRequest": self.dataTask.currentRequest ?: @"none",
    @"connection.originalRequest": self.dataTask.originalRequest ?: @"none",
  }];
}

/// ✅ Handle successful data load and display parsed content
- (void)handleLoadedData:(NSData *)data response:(NSURLResponse *)response {
  UIViewController *viewController = self.handler(self, data, response);

  if (!viewController) {
    [TPPErrorLogger logErrorWithCode:TPPErrorCodeUnableToMakeVCAfterLoading
                             summary:@"RemoteViewController: Failed to create VC after server-side load"
                            metadata:@{
      @"HTTPstatusCode": @([(NSHTTPURLResponse *)response statusCode] ?: -1),
      @"mimeType": response.MIMEType ?: @"N/A",
      @"URL": self.URL ?: @"N/A",
      @"response": response ?: @"N/A"
    }];
    [self showReloadViewWithMessage:NSLocalizedString(@"An error was encountered while parsing the server response.",
                                                      @"Generic error message for catalog load errors")];
    return;
  }

  [self addChildViewController:viewController];
  viewController.view.frame = self.view.bounds;
  [self.view addSubview:viewController.view];

  [self updateNavigationBarWithViewController:viewController];

  [viewController didMoveToParentViewController:self];
}

/// ✅ Copy navigation bar properties from the new ViewController
- (void)updateNavigationBarWithViewController:(UIViewController *)viewController {
  if (viewController.navigationItem.rightBarButtonItems) {
    self.navigationItem.rightBarButtonItems = viewController.navigationItem.rightBarButtonItems;
  }
  if (viewController.navigationItem.leftBarButtonItems) {
    self.navigationItem.leftBarButtonItems = viewController.navigationItem.leftBarButtonItems;
  }
  if (viewController.navigationItem.backBarButtonItem) {
    self.navigationItem.backBarButtonItem = viewController.navigationItem.backBarButtonItem;
  }
  if (viewController.navigationItem.title) {
    self.navigationItem.title = viewController.navigationItem.title;
  }
}

// TODO: SIMPLY-2862 This method should be removed as part of this ticket
- (void)reloadAccountsAndAuthenticationDocument
{
  TPPLOG_F(@"Reloading accounts from RemoteVC: %@", self.title);
  [AccountsManager.shared updateAccountSetWithCompletion:^(BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (success) {
        if (self.needsReauthentication) {
          self.needsReauthentication = NO;

          TPPUserAccount *user = [TPPUserAccount sharedAccount];
          __block TPPReauthenticator *reauthenticator = [[TPPReauthenticator alloc] init];
          [reauthenticator authenticateIfNeeded:user
                       usingExistingCredentials:YES
                       authenticationCompletion:^{
            // make sure to retain the reauthenticator until end of auth
            // flow and then break any possible retain cycle
            reauthenticator = nil;
            TPPLOG(@"Re-loading from RemoteVC because authentication had expired");
            [self load];
          }];
        } else {
          [self load];
          // Notify that all the accounts are re-authenticated
          [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPAccountSetDidLoad object:nil];
        }
      } else {
        [TPPErrorLogger logErrorWithCode:TPPErrorCodeNoURL
                                  summary:@"RemoteViewController: failed to reload accounts"
                                 metadata:@{
                                   @"currentURL": self.URL ?: @"N/A",
                                   @"ChildVCs": self.childViewControllers
                                 }];
        [self showReloadViewWithMessage:nil];
      }
    });
  }];
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.view.backgroundColor = [TPPConfiguration backgroundColor];
  
  self.activityIndicatorView = [[UIActivityIndicatorView alloc]
                                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  [self.view addSubview:self.activityIndicatorView];
  
  self.activityIndicatorLabel = [[UILabel alloc] init];
  self.activityIndicatorLabel.font = [UIFont palaceFontOfSize:14.0];
  self.activityIndicatorLabel.text = NSLocalizedString(@"Loading... Please wait.", @"Message explaining that the download is still going");
  self.activityIndicatorLabel.hidden = YES;
  [self.view addSubview:self.activityIndicatorLabel];
  [self.activityIndicatorLabel autoAlignAxis:ALAxisVertical toSameAxisOfView:self.activityIndicatorView];
  [self.activityIndicatorLabel autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:self.activityIndicatorView withOffset:8.0];
  
  // We always nil out the connection when not in use so this is reliable.
  if(self.dataTask) {
    [self.activityIndicatorView startAnimating];
  }
  
  __weak TPPRemoteViewController *weakSelf = self;
  self.reloadView = [[TPPReloadView alloc] init];
  self.reloadView.handler = ^{
    weakSelf.reloadView.hidden = YES;
    [weakSelf load];
  };
  self.reloadView.hidden = YES;
  [self.view addSubview:self.reloadView];
}

- (void)viewWillLayoutSubviews
{
  [super viewWillLayoutSubviews];

  [self.activityIndicatorView centerInSuperview];
  [self.reloadView centerInSuperview];
}

- (void)addActivityIndicatorLabel:(NSTimer*)timer
{
  if (!self.activityIndicatorView.isHidden) {
    [UIView transitionWithView:self.activityIndicatorLabel
                      duration:0.5
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                      self.activityIndicatorLabel.hidden = NO;
                    } completion:nil];
  }
  [timer invalidate];
}

#pragma mark Private Helpers

- (NSString *)messageFromProblemDocument:(TPPProblemDocument *)problemDoc
                                   error:(NSError *)error
{
  if (problemDoc && !problemDoc.stringValue.isEmptyNoWhitespace) {
    return problemDoc.stringValue;
  }

  if (error && !error.localizedDescriptionWithRecovery.isEmptyNoWhitespace) {
    return error.localizedDescriptionWithRecovery;
  }

  return NSLocalizedString(@"Load error. Please try signing out, then log in again.",
                           @"message for edge-case errors possibly related to authentication");
}

@end
