@interface TPPSettingsAccountDetailViewController : UITableViewController

- (nullable instancetype)initWithCoder:(nonnull NSCoder *)aDecoder NS_UNAVAILABLE;
- (nonnull instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;

/// The designated initializer.
/// @param libraryAccountUUID The ID of the library to sign in to.
- (nonnull instancetype)initWithLibraryAccountID:(nonnull NSString *)libraryAccountUUID;

/**
 * Update Library Card value
 *
 *@param username user name or library card value
 */
- (void)setUserName:(nonnull NSString *)username;

@end
