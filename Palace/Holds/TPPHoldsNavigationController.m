#import "Palace-Swift.h"
#import "TPPHoldsNavigationController.h"

@implementation TPPHoldsNavigationController

- (instancetype)init
{
    UIViewController *holdsView = [TPPHoldsViewController makeSwiftUIView];
    self = [super initWithRootViewController:holdsView];
    if (!self) return nil;

    self.tabBarItem.image = [UIImage imageNamed:@"Holds"];

    [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPSyncEnded object:nil];

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(currentAccountChanged)
               name:NSNotification.TPPCurrentAccountDidChange
             object:nil];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

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
