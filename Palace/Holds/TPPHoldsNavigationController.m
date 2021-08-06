#import "Palace-Swift.h"

#import "TPPHoldsViewController.h"
#import "TPPHoldsNavigationController.h"


@implementation TPPHoldsNavigationController

#pragma mark - NSObject

- (instancetype)init
{
  TPPHoldsViewController *vc = [[TPPHoldsViewController alloc] init];
  self = [super initWithRootViewController:vc];
  if(!self) return nil;
  
  self.tabBarItem.image = [UIImage imageNamed:@"Holds"];
  [vc updateBadge];

#ifdef SIMPLYE
  [self setNavigationLeftBarButtonForVC:vc];
#endif

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(currentAccountChanged) name:NSNotification.TPPCurrentAccountDidChange object:nil];
  
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UIViewController

-(void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  
  UIViewController *visibleVC = self.visibleViewController;
  visibleVC.navigationItem.title = [AccountsManager shared].currentAccount.name;
}

#pragma mark - Callbacks

- (void)currentAccountChanged
{
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self popToRootViewControllerAnimated:NO];
    });
  } else {
    [self popToRootViewControllerAnimated:NO];
  }
}

@end
