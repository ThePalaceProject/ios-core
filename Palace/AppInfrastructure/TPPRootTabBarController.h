@class TPPR3Owner;
@class TPPCatalogNavigationController;

@interface TPPRootTabBarController : UITabBarController

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;
- (id)initWithCoder:(NSCoder *)aDecoder NS_UNAVAILABLE;
- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil NS_UNAVAILABLE;

+ (instancetype)sharedController;

@property (readonly) TPPR3Owner *r3Owner;
@property (nonatomic) BOOL isPresentingSample;
@property(nonatomic, readonly) TPPCatalogNavigationController *catalogNavigationController;

/// This method will present a view controller from the receiver, or from the
/// controller currently being presented from the receiver, or from the
/// controller being presented by that one, and so on, such that no duplicate
/// presenting errors occur.
///
/// @note This methods assumes that the current window's root view controller
/// is the @p TPPRootTabBarController::sharedController.
///
- (void)safelyPresentViewController:(UIViewController *)viewController
                           animated:(BOOL)animated
                         completion:(void (^)(void))completion;

/// Pushes a view controller onto the navigation controller currently selected
/// by the underlying tab bar controller.
- (void)pushViewController:(UIViewController *const)viewController
                  animated:(BOOL const)animated;

@end
