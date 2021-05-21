@class TPPSettingsPrimaryTableViewController;

@interface TPPSettingsPrimaryNavigationController : UINavigationController

// The delegate of |primaryTableViewController| is nil by default and should be set by the
// instantiator of this class.
@property (nonatomic, readonly) TPPSettingsPrimaryTableViewController *primaryTableViewController;

@end
