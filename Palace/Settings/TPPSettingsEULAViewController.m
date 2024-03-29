@import WebKit;

#import "Palace-Swift.h"
#import "TPPConfiguration.h"
#import "TPPSettingsEULAViewController.h"

@interface TPPSettingsEULAViewController ()
@property (nonatomic) WKWebView *webView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UIActivityIndicatorView *activityIndicatorView;
@property (nonatomic) NSURL *eulaURL;

@end

@implementation TPPSettingsEULAViewController

- (instancetype)initWithAccount:(Account *)account
{
  self = [super init];
  if(!self) return nil;
  
  self.title = NSLocalizedString(@"User Agreement", nil);
  self.eulaURL = [account.details getLicenseURL:URLTypeEula];
  
  return self;
}

- (instancetype)initWithNYPLURL
{
  self = [super init];
  if(!self) return nil;
  
  self.title = NSLocalizedString(@"User Agreement", nil);
  self.eulaURL = [NSURL URLWithString:TPPSettings.TPPUserAgreementURLString];
  
  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.view.backgroundColor = [TPPConfiguration backgroundColor];

  self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds];
  self.webView.autoresizingMask = (UIViewAutoresizingFlexibleHeight
                                   | UIViewAutoresizingFlexibleWidth);
  self.webView.backgroundColor = [TPPConfiguration backgroundColor];
  self.webView.navigationDelegate = self;
  
  NSURLRequest *const request = [NSURLRequest requestWithURL:self.eulaURL
                                                 cachePolicy:NSURLRequestUseProtocolCachePolicy
                                             timeoutInterval:15.0];
  
  [self.webView loadRequest:request];
  [self.view addSubview:self.webView];
  
  self.activityIndicatorView =
  [[UIActivityIndicatorView alloc]
   initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  self.activityIndicatorView.center = self.view.center;
  self.activityIndicatorView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                                 UIViewAutoresizingFlexibleHeight);
  [self.activityIndicatorView startAnimating];
  [self.view addSubview:self.activityIndicatorView];
  
  if ( self == [self.navigationController.viewControllers objectAtIndex:0] ) {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Close", nil)
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(dismissEULA)];
  }
}

- (void)dismissEULA
{
  [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark WKNavigationDelegate

- (void)webView:(__unused WKWebView *)webView
didFailNavigation:(__unused WKNavigation *)navigation
      withError:(__unused NSError *)error
{
  [self.activityIndicatorView stopAnimating];

  UIAlertController *alertController = [UIAlertController
                                        alertControllerWithTitle:NSLocalizedString(@"Connection Failed", nil)
                                        message:NSLocalizedString(@"Unable to load the web page at this time.", nil)
                                        preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                                         style:UIAlertActionStyleDestructive
                                                       handler:^(UIAlertAction *cancelAction) {
                                                         if (cancelAction) {
                                                           [self.navigationController popViewControllerAnimated:YES];
                                                         }
                                                       }];

  UIAlertAction *reloadAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Reload", nil)
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction *reloadAction) {
                                                         if (reloadAction) {
                                                           NSURLRequest *const request = [NSURLRequest requestWithURL:self.eulaURL
                                                                                                          cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                                                                      timeoutInterval:15.0];

                                                           [self.webView loadRequest:request];
                                                         }
                                                       }];

  [alertController addAction:reloadAction];
  [alertController addAction:cancelAction];
  [self presentViewController:alertController
                     animated:NO
                   completion:nil];
}

- (void)webView:(__unused WKWebView *)webView
didFinishNavigation:(__unused WKNavigation *)navigation
{
  [self.activityIndicatorView stopAnimating];
}

@end
