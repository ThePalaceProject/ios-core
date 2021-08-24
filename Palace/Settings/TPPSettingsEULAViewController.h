@import WebKit;

@class Account;

@interface TPPSettingsEULAViewController : UIViewController <WKNavigationDelegate>

- (instancetype)initWithAccount:(Account *)account;
- (instancetype)initWithNYPLURL;

@end
