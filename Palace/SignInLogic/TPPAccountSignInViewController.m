@import LocalAuthentication;
@import CoreLocation;

#import <PureLayout/PureLayout.h>

#import "Palace-Swift.h"

#import "TPPAccountSignInViewController.h"
#import "TPPConfiguration.h"
#import "TPPLinearView.h"
#import "TPPOPDSFeed.h"
#import "TPPRootTabBarController.h"
#import "TPPSettingsEULAViewController.h"
#import "TPPXML.h"
#import "UIView+TPPViewAdditions.h"
#import "UIFont+TPPSystemFontOverride.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

static NSInteger sLinearViewTag = 1111;

typedef NS_ENUM(NSInteger, CellKind) {
  CellKindBarcode,
  CellKindPIN,
  CellKindLogIn,
  CellKindRegistration,
  CellKindPasswordReset
};

typedef NS_ENUM(NSInteger, Section) {
  SectionCredentials = 0,
  SectionRegistration = 1
};

// Note that this class does not actually have anything to do with logging out.
// The compliance with the TPPSignInOutBusinessLogicUIDelegate protocol
// is merely so that we can use this VC with the TPPSignInBusinessLogic
// class which is handling signing out too.
@interface TPPAccountSignInViewController () <TPPSignInOutBusinessLogicUIDelegate>

// view state
@property (nonatomic) BOOL loggingInAfterBarcodeScan;
@property (nonatomic) BOOL hiddenPIN;

// UI
@property (nonatomic) UIButton *barcodeScanButton;
@property (nonatomic) UITableViewCell *logInCell;
@property (nonatomic) UIButton *PINShowHideButton;
@property (nonatomic) NSArray *tableData;

// account state
@property (nonatomic) NSString *defaultUsername;
@property TPPUserAccountFrontEndValidation *frontEndValidator;
@property (nonatomic) TPPSignInBusinessLogic *businessLogic;

@end

@implementation TPPAccountSignInViewController

@synthesize usernameTextField;
@synthesize PINTextField;

CGFloat const marginPadding = 2.0;

#pragma mark - NYPLSignInOutBusinessLogicUIDelegate properties

- (NSString *)context
{
  return @"SignIn-modal";
}

- (NSString *)username
{
  return self.usernameTextField.text;
}

- (NSString *)pin
{
  return self.PINTextField.text;
}

#pragma mark - NSObject

- (instancetype)init
{
  self = [super initWithStyle:UITableViewStyleGrouped];
  if(!self) return nil;

#if FEATURE_DRM_CONNECTOR
  NYPLADEPT *adeptInstance = nil;
  if ([AdobeCertificate.defaultCertificate hasExpired] == NO) {
    adeptInstance = [NYPLADEPT sharedInstance];
  }
#endif
  
  self.businessLogic = [[TPPSignInBusinessLogic alloc]
                        initWithLibraryAccountID:AccountsManager.shared.currentAccountId
                        libraryAccountsProvider:AccountsManager.shared
                        urlSettingsProvider: TPPSettings.shared
                        bookRegistry:[TPPBookRegistry shared]
                        bookDownloadsCenter:[MyBooksDownloadCenter shared]
                        userAccountProvider:[TPPUserAccount class]
                        uiDelegate:self
                        drmAuthorizer:
#if FEATURE_DRM_CONNECTOR
                        adeptInstance
#else
                        nil
#endif
                        ];

  self.title = NSLocalizedString(@"Sign in", nil);

  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(accountDidChange)
   name:NSNotification.TPPUserAccountDidChange
   object:nil];
  
  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(keyboardDidShow:)
   name:UIKeyboardWillShowNotification
   object:nil];
  
  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(willResignActive)
   name:UIApplicationWillResignActiveNotification
   object:nil];

  [[NSNotificationCenter defaultCenter]
   addObserver:self
   selector:@selector(willEnterForeground)
   name:UIApplicationWillEnterForegroundNotification
   object:nil];
  
  self.frontEndValidator = [[TPPUserAccountFrontEndValidation alloc]
                            initWithAccount:self.businessLogic.libraryAccount
                            businessLogic:self.businessLogic
                            inputProvider:self];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.view.backgroundColor = [TPPConfiguration backgroundColor];
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

  self.usernameTextField = [[UITextField alloc] initWithFrame:CGRectZero];
  self.usernameTextField.delegate = self.frontEndValidator;
  self.usernameTextField.placeholder = AccountsManager.shared.currentAccount.details.defaultAuth.patronIDLabel ?: NSLocalizedString(@"Barcode or Username", nil);

  switch (self.businessLogic.selectedAuthentication.patronIDKeyboard) {
    case LoginKeyboardStandard:
    case LoginKeyboardNone:
      self.usernameTextField.keyboardType = UIKeyboardTypeASCIICapable;
      break;
    case LoginKeyboardEmail:
      self.usernameTextField.keyboardType = UIKeyboardTypeEmailAddress;
      break;
    case LoginKeyboardNumeric:
      self.usernameTextField.keyboardType = UIKeyboardTypeNumberPad;
      break;
  }

  self.usernameTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.usernameTextField.autocorrectionType = UITextAutocorrectionTypeNo;
  [self.usernameTextField
   addTarget:self
   action:@selector(textFieldsDidChange)
   forControlEvents:UIControlEventEditingChanged];
  
  self.PINTextField = [[UITextField alloc] initWithFrame:CGRectZero];
  self.PINTextField.placeholder = self.businessLogic.selectedAuthentication.pinLabel ?: NSLocalizedString(@"PIN", nil);

  switch (self.businessLogic.selectedAuthentication.pinKeyboard) {
    case LoginKeyboardStandard:
    case LoginKeyboardNone:
      self.PINTextField.keyboardType = UIKeyboardTypeASCIICapable;
      break;
    case LoginKeyboardEmail:
      self.PINTextField.keyboardType = UIKeyboardTypeEmailAddress;
      break;
    case LoginKeyboardNumeric:
      self.PINTextField.keyboardType = UIKeyboardTypeNumberPad;
      break;
  }

  self.PINTextField.secureTextEntry = YES;
  self.PINTextField.delegate = self.frontEndValidator;
  [self.PINTextField
   addTarget:self
   action:@selector(textFieldsDidChange)
   forControlEvents:UIControlEventEditingChanged];

  self.PINShowHideButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.PINShowHideButton setTitle:NSLocalizedString(@"Show", nil) forState:UIControlStateNormal];
  [self.PINShowHideButton sizeToFit];
  [self.PINShowHideButton addTarget:self action:@selector(PINShowHideSelected)
                   forControlEvents:UIControlEventTouchUpInside];
  self.PINTextField.rightView = self.PINShowHideButton;
  self.PINTextField.rightViewMode = UITextFieldViewModeAlways;

  self.barcodeScanButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.barcodeScanButton setImage:[UIImage imageNamed:@"CameraIcon"] forState:UIControlStateNormal];
  [self.barcodeScanButton addTarget:self action:@selector(scanLibraryCard)
                   forControlEvents:UIControlEventTouchUpInside];

  self.logInCell = [[UITableViewCell alloc]
                    initWithStyle:UITableViewCellStyleDefault
                    reuseIdentifier:nil];
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData) name:@"LocationAuthorizationDidChange" object:nil];
  
  [self setupTableData];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  
  // The new credentials are not yet saved after signup or after scanning. As such,
  // reloading the table would lose the values in the barcode and PIN fields.
  if (self.businessLogic.isLoggingInAfterSignUp || self.loggingInAfterBarcodeScan) {
    return;
  } else {
    self.hiddenPIN = YES;
    [self updateInputUIForcingEditability:self.forceEditability];
    [self updateShowHidePINState];
  }
  
  [self setupHeaderView];
}

- (void)appWillEnterForeground {
  [self.tableView reloadData];
}

- (void)reloadData {
  [self.tableView reloadData];
}

- (void) setupHeaderView
{
  UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.frame.size.width, 100)];
  UIView *containerView = [[UIView alloc] init];
  
  UIView *imageViewHolder = [[UIView alloc] init];
  [imageViewHolder autoSetDimension:ALDimensionHeight toSize:50.0];
  [imageViewHolder autoSetDimension:ALDimensionWidth toSize:50.0];

  UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 75, 75)];
  imageView.image = [[[AccountsManager shared] currentAccount] logo];
  imageView.contentMode = UIViewContentModeScaleAspectFit;
  [imageViewHolder addSubview: imageView];

  [imageView autoPinEdgesToSuperviewEdges];
  
  [headerView addSubview:containerView];
  [containerView addSubview:imageViewHolder];
  
  UILabel *titleLabel = [[UILabel alloc] init];
  titleLabel.numberOfLines = 0;
  titleLabel.textAlignment = NSTextAlignmentCenter;
  titleLabel.textColor = [UIColor grayColor];
  titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
  titleLabel.font = [UIFont boldSystemFontOfSize:18.0];
  titleLabel.text = [[AccountsManager shared] currentAccount].name;
  [containerView addSubview: titleLabel];
  
  self.tableView.tableHeaderView = headerView;
  
  [containerView autoAlignAxisToSuperviewAxis:ALAxisHorizontal];
  [containerView autoAlignAxisToSuperviewAxis:ALAxisVertical];
  [containerView autoPinEdgesToSuperviewMarginsWithInsets:UIEdgeInsetsMake(10, 10, 10, 10)];
  [imageViewHolder autoPinEdgesToSuperviewMarginsExcludingEdge:ALEdgeTrailing];
  [titleLabel autoPinEdgesToSuperviewMarginsExcludingEdge:ALEdgeLeading];
  [imageViewHolder autoPinEdge:ALEdgeTrailing toEdge:ALEdgeLeading ofView:titleLabel withOffset:-10];
}

#if defined(FEATURE_DRM_CONNECTOR)
- (void)viewDidAppear:(BOOL)animated
{
  [super viewDidAppear:animated];
  [self.businessLogic logInIfUserAuthorized];
}
#endif

#pragma mark UITableViewDelegate

- (void)tableView:(__attribute__((unused)) UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *const)indexPath
{
  NSArray *sectionArray = (NSArray *)self.tableData[indexPath.section];

  if ([sectionArray[indexPath.row] isKindOfClass:[TPPAuthMethodCellType class]]) {
    TPPAuthMethodCellType *methodCell = sectionArray[indexPath.row];
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];

    self.businessLogic.selectedIDP = nil;
    self.businessLogic.selectedAuthentication = methodCell.authenticationMethod;
    [self setupTableData];
    return;
  } else if ([sectionArray[indexPath.row] isKindOfClass:[TPPSamlIdpCellType class]]) {
    TPPSamlIdpCellType *idpCell = sectionArray[indexPath.row];
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];

    self.businessLogic.selectedIDP = idpCell.idp;
    [self.businessLogic logIn];
    return;
  } else if ([sectionArray[indexPath.row] isKindOfClass:[TPPInfoHeaderCellType class]]) {
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    return;
  }

  CellKind cellKind = (CellKind)[sectionArray[indexPath.row] intValue];

  switch(cellKind) {
    case CellKindBarcode:
      [self.usernameTextField becomeFirstResponder];
      break;
    case CellKindPIN:
      [self.PINTextField becomeFirstResponder];
      break;
    case CellKindLogIn:
      [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
      [self.businessLogic logIn];
      break;
    case CellKindPasswordReset:
      [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
      [self.businessLogic resetPassword];
      break;
    case CellKindRegistration:
      [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
      break;
  }
}

#pragma mark UITableViewDataSource

- (UITableViewCell *)tableView:(__attribute__((unused)) UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *const)indexPath
{
  NSArray *sectionArray = (NSArray *)self.tableData[indexPath.section];

  if ([sectionArray[indexPath.row] isKindOfClass:[TPPAuthMethodCellType class]]) {
    TPPAuthMethodCellType *methodCell = sectionArray[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc]
                             initWithStyle:UITableViewCellStyleDefault
                             reuseIdentifier:nil];
    cell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.text = methodCell.authenticationMethod.methodDescription;
    return cell;
  } else if ([sectionArray[indexPath.row] isKindOfClass:[TPPSamlIdpCellType class]]) {
    TPPSamlIdpCellType *idpCell = sectionArray[indexPath.row];
    TPPSamlIDPCell *cell = [[TPPSamlIDPCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.idpName.text = idpCell.idp.displayName;
    return cell;
  } else if ([sectionArray[indexPath.row] isKindOfClass:[TPPInfoHeaderCellType class]]) {
    TPPInfoHeaderCellType *infoCell = sectionArray[indexPath.row];
    TPPLibraryDescriptionCell *cell = [[TPPLibraryDescriptionCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.descriptionLabel.text = infoCell.information;
    return cell;
  }

  CellKind cellKind = (CellKind)[sectionArray[indexPath.row] intValue];

  switch(cellKind) {
    case CellKindBarcode: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      {
        self.usernameTextField.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
        [cell.contentView addSubview:self.usernameTextField];
        self.usernameTextField.preservesSuperviewLayoutMargins = YES;
        [self.usernameTextField autoPinEdgeToSuperviewMargin:ALEdgeRight];
        [self.usernameTextField autoPinEdgeToSuperviewMargin:ALEdgeLeft];
        [self.usernameTextField autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeMarginTop
                                                ofView:[self.usernameTextField superview]
                                            withOffset:marginPadding];
        [self.usernameTextField autoConstrainAttribute:ALAttributeBottom toAttribute:ALAttributeMarginBottom
                                                ofView:[self.usernameTextField superview]
                                            withOffset:-marginPadding];
        
        if (self.businessLogic.selectedAuthentication.supportsBarcodeScanner) {
          [cell.contentView addSubview:self.barcodeScanButton];
          CGFloat rightMargin = cell.layoutMargins.right;
          self.barcodeScanButton.contentEdgeInsets = UIEdgeInsetsMake(0, rightMargin * 2, 0, rightMargin);
          [self.barcodeScanButton autoPinEdgesToSuperviewEdgesWithInsets:UIEdgeInsetsZero excludingEdge:ALEdgeLeading];
          if (!self.usernameTextField.enabled) {
            self.barcodeScanButton.hidden = YES;
          }
        }
      }
      return cell;
    }
    case CellKindPIN: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      {
        self.PINTextField.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
        [cell.contentView addSubview:self.PINTextField];
        self.PINTextField.preservesSuperviewLayoutMargins = YES;
        [self.PINTextField autoPinEdgeToSuperviewMargin:ALEdgeRight];
        [self.PINTextField autoPinEdgeToSuperviewMargin:ALEdgeLeft];
        [self.PINTextField autoConstrainAttribute:ALAttributeTop toAttribute:ALAttributeMarginTop
                                           ofView:[self.PINTextField superview]
                                       withOffset:marginPadding];
        [self.PINTextField autoConstrainAttribute:ALAttributeBottom toAttribute:ALAttributeMarginBottom
                                           ofView:[self.PINTextField superview]
                                       withOffset:-marginPadding];
      }
      return cell;
    }
    case CellKindLogIn: {
      self.logInCell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      [self updateLoginCellAppearance];
      return self.logInCell;
    }
    case CellKindRegistration: {
      RegistrationCell *cell =  [RegistrationCell new];
      [cell configureWithTitle:nil body:nil buttonTitle:nil buttonAction:^{
        [self didSelectRegularSignupOnCell:cell];
      }];
      return cell;
    }
    case CellKindPasswordReset:
      return [self passwordResetCell];
    }
}

- (UITableViewCell *)passwordResetCell {
  UITableViewCell *cell = [[UITableViewCell alloc] init];
  cell.textLabel.text = NSLocalizedString(@"Forgot your password?", "Password Reset");
  return cell;
}

- (void)didSelectRegularSignupOnCell:(UITableViewCell *)cell
{
  [cell setUserInteractionEnabled:NO];
  __weak __auto_type weakSelf = self;
  [self.businessLogic startRegularCardCreationWithCompletion:^(UINavigationController * _Nullable navVC, NSError * _Nullable error) {
    [cell setUserInteractionEnabled:YES];
    if (error) {
      UIAlertController *alert = [TPPAlertUtils alertWithTitle:NSLocalizedString(@"Error", "Alert title") error:error];
      [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alert
                                                         viewController:nil
                                                               animated:YES
                                                             completion:nil];
      return;
    }

    [TPPMainThreadRun asyncIfNeeded:^{
      navVC.navigationBar.topItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Back", nil)
                                       style:UIBarButtonItemStylePlain
                                      target:weakSelf
                                      action:@selector(didSelectBackForSignUp)];
      navVC.modalPresentationStyle = UIModalPresentationFormSheet;
      [weakSelf presentViewController:navVC animated:YES completion:nil];
    }];

  }];
}

- (NSInteger)numberOfSectionsInTableView:(__attribute__((unused)) UITableView *)tableView
{
  return self.tableData.count;
}

- (NSInteger)tableView:(__attribute__((unused)) UITableView *)tableView
 numberOfRowsInSection:(NSInteger const)section
{
  if (section > (int)self.tableData.count - 1) {
    return 0;
  } else {
    return [(NSArray *)self.tableData[section] count];
  }
}

- (CGFloat)tableView:(UITableView *)__unused tableView heightForRowAtIndexPath:(NSIndexPath *)__unused indexPath {
  return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)__unused tableView heightForFooterInSection:(NSInteger)__unused section {
  return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)__unused tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)__unused indexPath {
  return 80;
}

- (CGFloat)tableView:(UITableView *)__unused tableView estimatedHeightForFooterInSection:(NSInteger)__unused section {
  return 80;
}

- (UIView *)tableView:(UITableView *)__unused tableView viewForFooterInSection:(NSInteger)section
{
  if (section == SectionCredentials && [self.businessLogic shouldShowEULALink]) {
    UIView *container = [[UIView alloc] init];
    container.preservesSuperviewLayoutMargins = YES;
    UILabel *footerLabel = [[UILabel alloc] init];
    footerLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleCaption1];
    footerLabel.textColor = [UIColor lightGrayColor];
    footerLabel.numberOfLines = 0;
    footerLabel.userInteractionEnabled = YES;

    NSDictionary *linkAttributes = @{ NSForegroundColorAttributeName :
                                        [UIColor colorWithRed:0.05 green:0.4 blue:0.65 alpha:1.0],
                                      NSUnderlineStyleAttributeName :
                                        @(NSUnderlineStyleSingle) };
    NSMutableAttributedString *eulaString = [[NSMutableAttributedString alloc]
                                             initWithString:NSLocalizedString(@"By signing in, you agree to the End User License Agreement.", nil) attributes:linkAttributes];
    footerLabel.attributedText = eulaString;
    [footerLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showEULA)]];

    [container addSubview:footerLabel];
    [footerLabel autoPinEdgeToSuperviewMargin:ALEdgeLeft];
    [footerLabel autoPinEdgeToSuperviewMargin:ALEdgeRight];
    [footerLabel autoPinEdgeToSuperviewEdge:ALEdgeTop withInset:8.0];
    [footerLabel autoPinEdgeToSuperviewEdge:ALEdgeBottom withInset:16.0 relation:NSLayoutRelationGreaterThanOrEqual];

    return container;

  } else {
    return nil;
  }
}

#pragma mark - Modal presentation

+ (void)requestCredentialsWithCompletion:(void (^)(void))completion
{
  [TPPAccountSignInViewController requestCredentialsForUsername:nil withCompletion:completion];
}

+ (void)requestCredentialsForUsername:(NSString *)username withCompletion:(void (^)(void))completion
{
  [TPPMainThreadRun asyncIfNeeded:^{
    TPPAccountSignInViewController *signInVC = [[self alloc] init];
    signInVC.defaultUsername = username;
    [signInVC presentIfNeededUsingExistingCredentials:NO
                                    completionHandler:completion];
  }];
}

/**
 * Presents itself to begin the login process.
 *
 * @param useExistingCredentials Should the screen be filled with the barcode when available?
 * @param completionHandler Called upon successful authentication
 */
- (void)presentIfNeededUsingExistingCredentials:(BOOL const)useExistingCredentials
                              completionHandler:(void (^)(void))completionHandler
{
  // Tell the VC to create its text fields so we can set their properties.
  [self view];

  BOOL shouldPresentVC = [self.businessLogic
                          refreshAuthIfNeededUsingExistingCredentials:useExistingCredentials
                          completion:completionHandler];

  if (shouldPresentVC) {
    [self presentAsModal];
  }
}

- (void)presentAsModal
{
  UIBarButtonItem *const cancelBarButtonItem =
  [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Cancel", "Cancel Button") style: UIBarButtonItemStylePlain target:self action:@selector(didSelectCancel)];

  self.navigationItem.leftBarButtonItem = cancelBarButtonItem;
  UINavigationController *const navVC = [[UINavigationController alloc]
                                         initWithRootViewController:self];
  navVC.modalPresentationStyle = UIModalPresentationFormSheet;

  [TPPPresentationUtils safelyPresent:navVC animated:YES completion:nil];
}

#pragma mark - Table view set up helpers

- (NSArray *)cellsForAuthMethod:(AccountDetailsAuthentication *)authenticationMethod {
  NSArray *authCells;

  if (authenticationMethod.isOauth) {
    // Oauth just needs the login button since it will open Safari for
    // actual authentication
    authCells = @[@(CellKindLogIn)];
  } else if (authenticationMethod.isSaml) {
    // make a list of all possible IDPs to login via SAML
    NSMutableArray *multipleCells = @[].mutableCopy;
    for (OPDS2SamlIDP *idp in authenticationMethod.samlIdps) {
      TPPSamlIdpCellType *idpCell = [[TPPSamlIdpCellType alloc] initWithIdp:idp];
      [multipleCells addObject:idpCell];
    }
    authCells = multipleCells;
  } else if (authenticationMethod.pinKeyboard != LoginKeyboardNone) {
    // if authentication method has an information about pin keyboard, the login method is requires a pin
    authCells = @[@(CellKindBarcode), @(CellKindPIN), @(CellKindLogIn)];
  } else {
    // if all other cases failed, it means that server expects just a barcode, with a blank pin
    self.PINTextField.text = @"";
    authCells = @[@(CellKindBarcode), @(CellKindLogIn)];
  }

  return authCells;
}

- (NSArray *)accountInfoSection {
  NSMutableArray *workingSection = @[].mutableCopy;
  if (!self.businessLogic.selectedAuthentication.needsAuth) {
    // no authentication needed, empty section

  } else if (self.businessLogic.selectedAuthentication && self.businessLogic.isSignedIn) {
    // user already logged in
    // show only the selected auth method

    [workingSection addObjectsFromArray:[self cellsForAuthMethod:self.businessLogic.selectedAuthentication]];
  } else if (!self.businessLogic.isSignedIn && self.businessLogic.userAccount.needsAuth) {
    // user needs to sign in

    if (self.businessLogic.isSamlPossible) {
      // TODO: SIMPLY-2884 add an information header that authentication is required
      NSString *libraryInfo = [NSString stringWithFormat:@"Log in to %@ required to download books.", self.businessLogic.libraryAccount.name];
      [workingSection addObject:[[TPPInfoHeaderCellType alloc] initWithInformation:libraryInfo]];
    }

    if (self.businessLogic.libraryAccount.details.auths.count > 1 && !self.businessLogic.libraryAccount.details.defaultAuth.isToken) {
      // multiple authentication methods
      for (AccountDetailsAuthentication *authMethod in self.businessLogic.libraryAccount.details.auths) {
        // show all possible login methods
        TPPAuthMethodCellType *authType = [[TPPAuthMethodCellType alloc] initWithAuthenticationMethod:authMethod];
        [workingSection addObject:authType];
        if (authMethod.methodDescription == self.businessLogic.selectedAuthentication.methodDescription) {
          // selected method, unfold
          [workingSection addObjectsFromArray:[self cellsForAuthMethod:authMethod]];
        }
      }
    } else if (self.businessLogic.libraryAccount.details.auths.count == 1) {
      // only 1 authentication method
      // no method header needed
      [workingSection addObjectsFromArray:[self cellsForAuthMethod:self.businessLogic.libraryAccount.details.auths[0]]];
    } else if (self.businessLogic.selectedAuthentication) {
      // only 1 authentication method
      // no method header needed
      [workingSection addObjectsFromArray:[self cellsForAuthMethod:self.businessLogic.selectedAuthentication]];
    }
    
    if (self.businessLogic.canResetPassword) {
      [workingSection addObject:@(CellKindPasswordReset)];
    }
    
  } else {
    [workingSection addObjectsFromArray:[self cellsForAuthMethod:self.businessLogic.selectedAuthentication]];
  }
  return workingSection;
}

- (void)setupTableData
{
  NSArray *section0AcctInfo = [self accountInfoSection];

  if ([self.businessLogic registrationIsPossible])   {
    self.tableData = @[section0AcctInfo, @[@(CellKindRegistration)]];
  } else {
    self.tableData = @[section0AcctInfo];
  }
  
  [self.tableView reloadData];
}

#pragma mark - PIN Show/Hide

- (void)PINShowHideSelected
{
  if(self.PINTextField.text.length > 0 && self.PINTextField.secureTextEntry) {
    LAContext *const context = [[LAContext alloc] init];
    if([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:NULL]) {
      [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
              localizedReason:NSLocalizedString(@"Authenticate to reveal your PIN.", nil)
                        reply:^(__unused BOOL success,
                                __unused NSError *_Nullable error) {
                          if(success) {
                            [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                              [self togglePINShowHideState];
                            }];
                          }
                        }];
    } else {
      [self togglePINShowHideState];
    }
  } else {
    [self togglePINShowHideState];
  }
}

- (void)togglePINShowHideState
{
  self.PINTextField.secureTextEntry = !self.PINTextField.secureTextEntry;
  NSString *title = self.PINTextField.secureTextEntry ? @"Show" : @"Hide";
  [self.PINShowHideButton setTitle:NSLocalizedString(title, nil) forState:UIControlStateNormal];
  [self.PINShowHideButton sizeToFit];
  [self.tableView reloadData];
}

- (void)updateShowHidePINState
{
  self.PINTextField.rightView.hidden = YES;

  LAContext *const context = [[LAContext alloc] init];
  if([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:NULL]) {
    self.PINTextField.rightView.hidden = NO;
  }
}

#pragma mark -

- (void)scanLibraryCard
{
  [TPPBarcode presentScannerWithCompletion:^(NSString * _Nullable resultString) {
    if (resultString) {
      self.usernameTextField.text = resultString;
      [self.PINTextField becomeFirstResponder];
      self.loggingInAfterBarcodeScan = YES;
    }
  }];
}

- (void)didSelectCancel
{
  [self.navigationController.presentingViewController
   dismissViewControllerAnimated:YES
   completion:nil];
}

- (void)didSelectBackForSignUp
{
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showEULA
{
  UIViewController *eulaViewController = [[TPPSettingsEULAViewController alloc] initWithAccount:self.businessLogic.libraryAccount];
  UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:eulaViewController];
  [self.navigationController presentViewController:navVC animated:YES completion:nil];
}

#pragma mark - UI update

- (void)accountDidChange
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [self updateInputUIForcingEditability:NO];
  }];
}

- (void)updateInputUIForcingEditability:(BOOL)forceEditability
{
  if(self.businessLogic.isSignedIn) {
    self.usernameTextField.text = self.businessLogic.userAccount.barcode;
    self.usernameTextField.enabled = forceEditability;
    self.PINTextField.text = self.businessLogic.userAccount.PIN;
    self.PINTextField.enabled = forceEditability;
    if (forceEditability) {
      self.usernameTextField.textColor = [UIColor blackColor];
      self.PINTextField.textColor = [UIColor blackColor];
    } else {
      self.usernameTextField.textColor = [UIColor grayColor];
      self.PINTextField.textColor = [UIColor grayColor];
    }
  } else {
    self.usernameTextField.text = self.defaultUsername;
    self.usernameTextField.enabled = YES;
    self.usernameTextField.textColor = [UIColor defaultLabelColor];
    self.PINTextField.text = nil;
    self.PINTextField.enabled = YES;
    self.PINTextField.textColor = [UIColor defaultLabelColor];
  }

  [self setupTableData];
  [self updateLoginCellAppearance];
  
  if (self.defaultUsername) {
    self.defaultUsername = nil; // clear default username
    [PINTextField becomeFirstResponder];
  }
}

- (void)updateLoginCellAppearance
{
  if (self.businessLogic.isValidatingCredentials) {
    return;
  }

  if (self.businessLogic.isSignedIn && !self.forceEditability) {
    return;
  }

  self.logInCell.textLabel.text = NSLocalizedString(@"Sign in", nil);
  BOOL const barcodeHasText = [self.usernameTextField.text
                               stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length;
  BOOL const pinHasText = [self.PINTextField.text
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length;
  BOOL const pinIsNotRequired = self.businessLogic.selectedAuthentication.pinKeyboard == LoginKeyboardNone;
  BOOL const oauthLogin = self.businessLogic.selectedAuthentication.isOauth;

  if ((barcodeHasText && (pinHasText || pinIsNotRequired)) || oauthLogin) {
    self.logInCell.userInteractionEnabled = YES;
    self.logInCell.textLabel.textColor = [TPPConfiguration mainColor];
  } else {
    self.logInCell.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) {
      self.logInCell.textLabel.textColor = [UIColor systemGray2Color];
    } else {
      self.logInCell.textLabel.textColor = [UIColor lightGrayColor];
    }
  }
}

- (void)displayErrorMessage:(NSString *)errorMessage
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = errorMessage;
    [label sizeToFit];
    label.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    [self.view addSubview:label];
}

- (void)setActivityTitleWithText:(NSString *)text
{
  // since we are adding a subview to self.logInCell.contentView, there
  // is no point in continuing if for some reason logInCell is nil.
  if (self.logInCell.contentView == nil) {
    return;
  }

  // check if we already added the activity view
  if ([self.logInCell.contentView viewWithTag:sLinearViewTag] != nil) {
    return;
  }
  
  UIActivityIndicatorView *const activityIndicatorView =
  [[UIActivityIndicatorView alloc]
   initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  
  [activityIndicatorView startAnimating];
  
  UILabel *const titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  titleLabel.text = text;
  titleLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
  [titleLabel sizeToFit];
  
  // This view is used to keep the title label centered as in Apple's Settings application.
  UIView *const rightPaddingView = [[UIView alloc] initWithFrame:activityIndicatorView.bounds];

  TPPLinearView *const linearView = [[TPPLinearView alloc] init];
  linearView.tag = sLinearViewTag;
  linearView.contentVerticalAlignment = TPPLinearViewContentVerticalAlignmentMiddle;
  linearView.padding = 5.0;
  [linearView addSubview:activityIndicatorView];
  [linearView addSubview:titleLabel];
  [linearView addSubview:rightPaddingView];
  [linearView sizeToFit];
  [linearView autoSetDimensionsToSize:CGSizeMake(linearView.frame.size.width, linearView.frame.size.height)];
  
  self.logInCell.textLabel.text = nil;
  [self.logInCell.contentView addSubview:linearView];
  [linearView autoCenterInSuperview];
}

- (void)removeActivityTitle
{
  UIView *view = [self.logInCell.contentView viewWithTag:sLinearViewTag];
  [view removeFromSuperview];
  [self updateLoginCellAppearance];
}

#pragma mark - Text Input

- (void)textFieldsDidChange
{
  [self updateLoginCellAppearance];
}

- (void)keyboardDidShow:(NSNotification *const)notification
{
  // This nudges the scroll view up slightly so that the log in button is clearly visible even on
  // older 3:2 iPhone displays. I wish there were a more general way to do this, but this does at
  // least work very well.
  
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    if((UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) ||
       (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact &&
        self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact)) {
      CGSize const keyboardSize =
      [[notification userInfo][UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;
      CGRect visibleRect = self.view.frame;
      visibleRect.size.height -= keyboardSize.height + self.tableView.contentInset.top;
      if(!CGRectContainsPoint(visibleRect,
                              CGPointMake(0, CGRectGetMaxY(self.logInCell.frame)))) {
        // We use an explicit animation block here because |setContentOffset:animated:| does not seem
        // to work at all.
        [UIView animateWithDuration:0.25 animations:^{
          [self.tableView setContentOffset:CGPointMake(0, -self.tableView.contentInset.top + 20)];
        }];
      }
    }
  }];
}

#pragma mark - UIApplication observer callbacks

- (void)willResignActive
{
  if(!self.PINTextField.secureTextEntry) {
    [self togglePINShowHideState];
  }
}

- (void)willEnterForeground
{
  // We update the state again in case the user enabled or disabled an authentication mechanism.
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [self updateShowHidePINState];
  }];
}

#pragma mark - NYPLSignInOutBusinessLogicUIDelegate

- (void)businessLogicWillSignIn:(TPPSignInBusinessLogic *)businessLogic
{
  if (!businessLogic.selectedAuthentication.isOauth
      && !businessLogic.selectedAuthentication.isSaml) {
    [self.usernameTextField resignFirstResponder];
    [self.PINTextField resignFirstResponder];
    [self setActivityTitleWithText:NSLocalizedString(@"Verifying", nil)];
  }
}

/**
 @note This method is not doing any logging in case `success` is false.

 @param success Whether Adobe DRM authorization was successful or not.
 @param error If errorMessage is absent, this will be used to derive a message
 to present to the user.
 @param errorMessage Will be presented to the user and will be used as a
 localization key to attempt to localize it.
 */
- (void)businessLogicDidCompleteSignIn:(TPPSignInBusinessLogic *)businessLogic
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [self removeActivityTitle];
  }];
}

- (void)      businessLogic:(TPPSignInBusinessLogic *)businessLogic
didEncounterValidationError:(NSError *)error
     userFriendlyErrorTitle:(NSString *)title
                 andMessage:(NSString *)serverMessage
{
  [self removeActivityTitle];

  if (error.code == NSURLErrorCancelled) {
    // We cancelled the request when asked to answer the server's challenge
    // a second time because we don't have valid credentials.
    self.PINTextField.text = @"";
    [self textFieldsDidChange];
    [self.PINTextField becomeFirstResponder];
  }

  UIAlertController *alert = nil;
  if (serverMessage != nil) {
    alert = [TPPAlertUtils alertWithTitle:title
                                   message:serverMessage];
  } else {
    alert = [TPPAlertUtils alertWithTitle:title
                                     error:error];
  }

  [TPPPresentationUtils safelyPresent:alert animated:YES completion:nil];
}

- (void)   businessLogic:(TPPSignInBusinessLogic *)logic
didEncounterSignOutError:(NSError *)error
      withHTTPStatusCode:(NSInteger)statusCode
{
}

- (void)businessLogicWillSignOut:(TPPSignInBusinessLogic *)businessLogic
{
}

- (void)businessLogicDidFinishDeauthorizing:(TPPSignInBusinessLogic *)businessLogic
{
}

@end
