@import LocalAuthentication;
@import CoreLocation;
@import MessageUI;
@import PureLayout;

#import "TPPConfiguration.h"
#import "TPPLinearView.h"
#import "TPPOPDS.h"
#import "TPPSettingsAccountDetailViewController.h"
#import "TPPSettingsEULAViewController.h"
#import "TPPXML.h"
#import "UIFont+TPPSystemFontOverride.h"
#import "UIView+TPPViewAdditions.h"
#import "Palace-Swift.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

typedef NS_ENUM(NSInteger, CellKind) {
  CellKindAdvancedSettings,
  CellKindAgeCheck,
  CellKindBarcodeImage,
  CellKindBarcode,
  CellKindPIN,
  CellKindLogInSignOut,
  CellKindRegistration,
  CellKindSyncButton,
  CellKindAbout,
  CellKindPrivacyPolicy,
  CellKindContentLicense,
  CellReportIssue,
  CellKindPasswordReset
};

@interface TPPSettingsAccountDetailViewController () <TPPSignInOutBusinessLogicUIDelegate>

// view state
@property (nonatomic) BOOL loggingInAfterBarcodeScan;
@property (nonatomic) BOOL hiddenPIN;

// UI
@property (nonatomic) UIImageView *barcodeImageView;
@property (nonatomic) UILabel *barcodeTextLabel;
@property (nonatomic) UILabel *barcodeImageLabel;
@property (nonatomic) NSLayoutConstraint *barcodeHeightConstraint;
@property (nonatomic) NSLayoutConstraint *barcodeTextHeightConstraint;
@property (nonatomic) NSLayoutConstraint *barcodeTextLabelSpaceConstraint;
@property (nonatomic) NSLayoutConstraint *barcodeLabelSpaceConstraint;
@property (nonatomic) float userBrightnessSetting;
@property (nonatomic) NSMutableArray *tableData;
@property (nonatomic) UIButton *PINShowHideButton;
@property (nonatomic) UIButton *barcodeScanButton;
@property (nonatomic) UITableViewCell *logInSignOutCell;
@property (nonatomic) UITableViewCell *ageCheckCell;
@property (nonatomic) UISwitch *syncSwitch;
@property (nonatomic) UIView *accountInfoHeaderView;
@property (nonatomic) UIView *accountInfoFooterView;
@property (nonatomic) UIView *syncFooterView;
@property (nonatomic) UIActivityIndicatorView *juvenileActivityView;
@property (nonatomic) TPPSamlIDPCell *idpCell;

// account state
@property TPPUserAccountFrontEndValidation *frontEndValidator;
@property (nonatomic) TPPSignInBusinessLogic *businessLogic;

@end

static const NSInteger sLinearViewTag = 1111;
static const CGFloat sVerticalMarginPadding = 2.0;

// table view sections indeces
static const NSInteger sSection0AccountInfo = 0;
static const NSInteger sSection1Sync = 1;

// Constraint constants
static const CGFloat sConstantZero = 0.0;
static const CGFloat sConstantSpacing = 12.0;

@implementation TPPSettingsAccountDetailViewController

/*
 For NYPL, this field can accept any of the following:
 - a username
 - a 14-digit NYPL-issued barcode
 - a 16-digit NYC ID issued by the city of New York to its residents. Patrons
 can set up the NYC ID as a NYPL barcode even if they already have a NYPL card.
 All of these types of authentication can be used with the PIN to sign in.
 - Note: A patron can have multiple barcodes, because patrons may lose
their library card and get a new one with a different barcode.
Authenticating with any of those barcodes should work.
 */
@synthesize usernameTextField;

@synthesize PINTextField;

@synthesize forceEditability;

#pragma mark - NYPLSignInOutBusinessLogicUIDelegate properties

- (NSString *)context
{
  return @"Settings Tab";
}

- (NSString *)username
{
  return self.usernameTextField.text;
}

- (NSString *)pin
{
  return self.PINTextField.text;
}

#pragma mark - Computed variables

- (NSString *)selectedAccountId
{
  return self.businessLogic.libraryAccountID;
}

- (nullable Account *)selectedAccount
{
  return self.businessLogic.libraryAccount;
}

- (TPPUserAccount *)selectedUserAccount
{
  return self.businessLogic.userAccount;
}

#pragma mark - NSObject

// Overriding superclass's designated initializer
- (instancetype)initWithStyle:(__unused UITableViewStyle)style
{
  NSString *libraryID = [[AccountsManager shared] currentAccountId];
  NSAssert(libraryID, @"Tried to initialize NYPLSettingsAccountDetailViewController with the current library ID but that appears to be nil. A release build will continue with an empty library ID but this will likely produce unexpected behavior.");
  return [self initWithLibraryAccountID:libraryID ?: @""];
}

- (instancetype)initWithLibraryAccountID:(NSString *)libraryUUID
{
  self = [super initWithStyle:UITableViewStyleGrouped];
  if(!self) return nil;

  id<TPPDRMAuthorizing> drmAuthorizer = nil;
#if defined(FEATURE_DRM_CONNECTOR)
  if ([AdobeCertificate.defaultCertificate hasExpired] == NO) {
    drmAuthorizer = [NYPLADEPT sharedInstance];
  }
#endif

  self.businessLogic = [[TPPSignInBusinessLogic alloc]
                        initWithLibraryAccountID:libraryUUID
                        libraryAccountsProvider:AccountsManager.shared
                        urlSettingsProvider: TPPSettings.shared
                        bookRegistry:[TPPBookRegistry shared]
                        bookDownloadsCenter:[MyBooksDownloadCenter shared]
                        userAccountProvider:[TPPUserAccount class]
                        uiDelegate:self
                        drmAuthorizer:drmAuthorizer];

  self.title = NSLocalizedString(@"Account", nil);

  self.frontEndValidator = [[TPPUserAccountFrontEndValidation alloc]
                            initWithAccount:self.selectedAccount
                            businessLogic:self.businessLogic
                            inputProvider:self];

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
  
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UIViewController + Views Preparation

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.view.backgroundColor = [TPPConfiguration backgroundColor];
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  [self setupHeaderView];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData) name:@"LocationAuthorizationDidChange" object:nil];

  UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle: UIActivityIndicatorViewStyleMedium];
  activityIndicator.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
  [self.view addSubview:activityIndicator];
  [activityIndicator startAnimating];
  
  __weak TPPSettingsAccountDetailViewController *weakSelf = self;
    
  if (self.businessLogic.libraryAccount.details) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [activityIndicator removeFromSuperview];
      [weakSelf setupViews];
      weakSelf.hiddenPIN = YES;
      [weakSelf accountDidChange];
      [weakSelf updateShowHidePINState];
    });
  } else {
    [self.businessLogic ensureAuthenticationDocumentIsLoaded:^(BOOL success) {
      if (success) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [activityIndicator removeFromSuperview];
          [weakSelf setupViews];
          weakSelf.hiddenPIN = YES;
          [weakSelf accountDidChange];
          [weakSelf updateShowHidePINState];
        });
      } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [activityIndicator removeFromSuperview];
          [weakSelf displayErrorMessage:NSLocalizedString(@"Please check your connection and try again.", nil)];
        });
      }
    }];
  }
}

- (void)appWillEnterForeground {
  [self.tableView reloadData];
}

- (void)reloadData {
  [self.tableView reloadData];
}

- (void)displayErrorMessage:(NSString *)errorMessage
{
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
  label.text = errorMessage;
  [label sizeToFit];
  [self.view addSubview:label];
  [label centerInSuperviewWithOffset:self.tableView.contentOffset];
}

- (void)setupViews
{
  self.usernameTextField = [[UITextField alloc] initWithFrame:CGRectZero];
  self.usernameTextField.delegate = self.frontEndValidator;
  self.usernameTextField.placeholder =
  self.businessLogic.selectedAuthentication.patronIDLabel ?: NSLocalizedString(@"Barcode or Username", nil);

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

  self.barcodeScanButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.barcodeScanButton setImage:[UIImage imageNamed:@"CameraIcon"] forState:UIControlStateNormal];
  [self.barcodeScanButton addTarget:self action:@selector(scanLibraryCard)
                   forControlEvents:UIControlEventTouchUpInside];
  
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

  [self setupTableData];
  
  self.syncSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
}

- (NSArray *) cellsForAuthMethod:(AccountDetailsAuthentication *)authenticationMethod {
  NSArray *authCells;

  if (authenticationMethod.isOauth) {
    // if authentication method is Oauth, just insert login/logout button, it will decide what to do by itself
    authCells = @[@(CellKindLogInSignOut)];
  } else if (authenticationMethod.isSaml && self.businessLogic.isSignedIn) {
    // if authentication method is SAML and user is already logged, the only possible action is to logout
    // add login/logout button, it will detect by itself that it should be log out in this case
    authCells = @[@(CellKindLogInSignOut)];
  } else if (authenticationMethod.isSaml) {
    // if authentication method is SAML and previous case wasn't fullfilled, make a list of all possible IDPs to login
    NSMutableArray *multipleCells = @[].mutableCopy;
    for (OPDS2SamlIDP *idp in authenticationMethod.samlIdps) {
      TPPSamlIdpCellType *idpCell = [[TPPSamlIdpCellType alloc] initWithIdp:idp];
      [multipleCells addObject:idpCell];
    }
    authCells = multipleCells;
  } else if (authenticationMethod.pinKeyboard != LoginKeyboardNone) {
    // if authentication method has an information about pin keyboard, the login method is requires a pin
    authCells = @[@(CellKindBarcode), @(CellKindPIN), @(CellKindLogInSignOut)];
  } else {
    // if all other cases failed, it means that server expects just a barcode, with a blank pin
    self.PINTextField.text = @"";
    authCells = @[@(CellKindBarcode), @(CellKindLogInSignOut)];
  }

  return authCells;
}

- (NSArray *) accountInfoSection {
  NSMutableArray *workingSection = @[].mutableCopy;
  if (self.businessLogic.selectedAuthentication.needsAgeCheck) {
    workingSection = @[@(CellKindAgeCheck)].mutableCopy;
  } else if (!self.businessLogic.selectedAuthentication.needsAuth) {
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
      for (AccountDetailsAuthentication *authenticationMethod in self.businessLogic.libraryAccount.details.auths) {
        // show all possible login methods
        TPPAuthMethodCellType *autheticationCell = [[TPPAuthMethodCellType alloc] initWithAuthenticationMethod:authenticationMethod];
        [workingSection addObject:autheticationCell];
        if (authenticationMethod.methodDescription == self.businessLogic.selectedAuthentication.methodDescription) {
          // selected method, unfold
          [workingSection addObjectsFromArray:[self cellsForAuthMethod:authenticationMethod]];
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

  if ([self.businessLogic librarySupportsBarcodeDisplay]) {
    [workingSection insertObject:@(CellKindBarcodeImage) atIndex:0];
  }

  return workingSection;
}

- (void)setupTableData
{
  NSArray *section0AcctInfo = [self accountInfoSection];

  NSMutableArray *section2About = [[NSMutableArray alloc] init];
  if ([self.selectedAccount.details getLicenseURL:URLTypePrivacyPolicy]) {
    [section2About addObject:@(CellKindPrivacyPolicy)];
  }
  if ([self.selectedAccount.details getLicenseURL:URLTypeContentLicenses]) {
    [section2About addObject:@(CellKindContentLicense)];
  }
  NSMutableArray *section1Sync = [[NSMutableArray alloc] init];
  if ([self.businessLogic shouldShowSyncButton]) {
    [section1Sync addObject:@(CellKindSyncButton)];
    [section2About addObject:@(CellKindAdvancedSettings)];
  }
  
  if ([self.businessLogic registrationIsPossible])   {
    self.tableData = @[section0AcctInfo, @[@(CellKindRegistration)], section1Sync].mutableCopy;
  } else {
    self.tableData = @[section0AcctInfo, section1Sync].mutableCopy;
  }

  if (self.selectedAccount.hasSupportOption) {
    [self.tableData addObject:@[@(CellReportIssue)]];
  }
  
  [self.tableData addObject:section2About];

  // compute final tableview contents, adding all non-empty sections
  NSMutableArray *finalTableContents = [[NSMutableArray alloc] init];
  for (NSArray *section in self.tableData) {
    if ([section count] != 0) {
      [finalTableContents addObject:section];
    }
  }
  self.tableData = finalTableContents;
  [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];

  // The new credentials are not yet saved after signup or after scanning. As such,
  // reloading the table would lose the values in the barcode and PIN fields.
  if (self.businessLogic.isLoggingInAfterSignUp || self.loggingInAfterBarcodeScan || self.businessLogic.isValidatingCredentials) {
    return;
  } else {
    self.hiddenPIN = YES;
    [self accountDidChange];
    [self updateShowHidePINState];
  }
}

- (void)viewWillDisappear:(BOOL)animated
{
  [super viewWillDisappear:animated];
  if (self.userBrightnessSetting && [[UIScreen mainScreen] brightness] != self.userBrightnessSetting) {
    [[UIScreen mainScreen] setBrightness:self.userBrightnessSetting];
  }
}

- (void)viewWillTransitionToSize:(__unused CGSize)size
       withTransitionCoordinator:(__unused id<UIViewControllerTransitionCoordinator>)coordinator
{
  [self.tableView reloadData];
}

/**
 * Update Library Card value
 *
 *@param username user name or library card value
 */
- (void)setUserName:(nonnull NSString *)username
{
  usernameTextField.text = username;
  [PINTextField becomeFirstResponder];
}

#pragma mark - Account SignOut

- (void)logOut
{
  UIAlertController *alert = [self.businessLogic logOutOrWarn];
  if (alert) {
    [self presentViewController:alert animated:YES completion:nil];
  }
}

- (void)showLogoutAlertWithError:(NSError *)error responseCode:(NSInteger)code
{
  NSString *title; NSString *message;
  if (code == 401) {
    title = @"Unexpected Credentials";
    message = @"Your username or password may have changed since the last time you logged in.\n\nIf you believe this is an error, please contact your library.";
  } else if (error) {
    title = @"SettingsAccountViewControllerLogoutFailed";
    message = error.localizedDescription;
  } else {
    title = @"SettingsAccountViewControllerLogoutFailed";
    message = NSLocalizedString(@"An unknown error occurred while trying to sign out.", nil);
  }
  [self presentViewController:[TPPAlertUtils alertWithTitle:title message:message]
                     animated:YES
                   completion:nil];
}

#pragma mark - UITableViewDataSource / UITableViewDelegate + related methods

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
    [self setupTableData];
    return;
  } else if ([sectionArray[indexPath.row] isKindOfClass:[TPPSamlIdpCellType class]]) {

    TPPSamlIdpCellType *cellType = sectionArray[indexPath.row];
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];

    self.idpCell = [self.tableView cellForRowAtIndexPath:indexPath];

    [self showSAMLLoginActivityView];

    self.businessLogic.selectedIDP = cellType.idp;
    [self.businessLogic logIn];

    return;
  } else if ([sectionArray[indexPath.row] isKindOfClass:[TPPInfoHeaderCellType class]]) {
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    return;
  }

  CellKind cellKind = (CellKind)[sectionArray[indexPath.row] intValue];
  
  switch(cellKind) {
    case CellKindAgeCheck: {
      [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
      UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
      
      if (!TPPSettings.shared.userPresentedAgeCheck) {
        __weak TPPSettingsAccountDetailViewController *weakSelf = self;
        [[[AccountsManager shared] ageCheck] verifyCurrentAccountAgeRequirementWithUserAccountProvider:self.businessLogic.userAccount
                                                                         currentLibraryAccountProvider:self.businessLogic
                                                                                            completion:^(BOOL aboveAgeLimit) {
          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage imageNamed: @"CheckedCircle"]];
            weakSelf.selectedAccount.details.userAboveAgeLimit = aboveAgeLimit;
            if (!aboveAgeLimit) {
              [[MyBooksDownloadCenter shared] reset:weakSelf.selectedAccountId];
              [[TPPBookRegistry shared] reset:weakSelf.selectedAccountId];
            }
            // Notify and let SwiftUI Catalog handle refresh
            [[NSNotificationCenter defaultCenter] postNotificationName:NSNotification.TPPCurrentAccountDidChange object:nil];
            // SwiftUI Catalog listens to TPPCurrentAccountDidChange and updates
          }];
        }];
      }
      break;
    }
    case CellKindBarcode:
      [self.usernameTextField becomeFirstResponder];
      break;
    case CellKindPIN:
      [self.PINTextField becomeFirstResponder];
      break;
    case CellKindLogInSignOut: {
      [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
      NSString *logoutString;
      if([self.selectedUserAccount hasCredentials]) {
        if ([self.businessLogic shouldShowSyncButton] && !self.syncSwitch.on) {
          logoutString = NSLocalizedString(@"If you sign out without enabling Sync, your books and any saved bookmarks will be removed.", nil);
        } else {
          logoutString = NSLocalizedString(@"If you sign out, your books and any saved bookmarks will be removed.", nil);
        }
        UIAlertController *const alertController =
        (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
         (self.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassCompact))
        ? [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Sign out", nil)
                                              message:logoutString
                                       preferredStyle:UIAlertControllerStyleAlert]
        : [UIAlertController alertControllerWithTitle:logoutString
                                              message:nil
                                       preferredStyle:UIAlertControllerStyleActionSheet];
        alertController.popoverPresentationController.sourceRect = self.view.bounds;
        alertController.popoverPresentationController.sourceView = self.view;
        [alertController addAction:[UIAlertAction
                                    actionWithTitle:NSLocalizedString(@"Sign out", @"Title for sign out action")
                                    style:UIAlertActionStyleDestructive
                                    handler:^(__attribute__((unused)) UIAlertAction *action) {
                                      [self logOut];
                                    }]];
        [alertController addAction:[UIAlertAction
                                    actionWithTitle:NSLocalizedString(@"Cancel", nil)
                                    style:UIAlertActionStyleCancel
                                    handler:nil]];
        [self presentViewController:alertController animated:YES completion:^{
          alertController.view.tintColor = [TPPConfiguration mainColor];
        }];
      } else {
        [self.businessLogic logInWith:[self.selectedUserAccount.authDefinition tokenURL]];
      }
      break;
    }
    case CellKindRegistration: {
      [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
      break;
    }
    case CellKindSyncButton: {
      break;
    }
    case CellKindAdvancedSettings: {
      TPPSettingsAdvancedViewController *vc = [[TPPSettingsAdvancedViewController alloc] initWithAccount:self.selectedAccountId];
      [self.navigationController pushViewController:vc animated:YES];
      break;
    }
    case CellKindBarcodeImage: {
      [self.tableView beginUpdates];
      if (self.barcodeImageView.bounds.size.height > sConstantZero) {
        self.barcodeHeightConstraint.constant = sConstantZero;
        self.barcodeTextHeightConstraint.constant = sConstantZero;
        self.barcodeTextLabelSpaceConstraint.constant = sConstantZero;
        self.barcodeLabelSpaceConstraint.constant = sConstantZero;
        self.barcodeImageLabel.text = NSLocalizedString(@"Show Barcode", nil);
        [[UIScreen mainScreen] setBrightness:self.userBrightnessSetting];
      } else {
        self.barcodeHeightConstraint.constant = 100.0;
        self.barcodeTextHeightConstraint.constant = 30.0;
        self.barcodeTextLabelSpaceConstraint.constant = -sConstantSpacing;
        self.barcodeLabelSpaceConstraint.constant = -sConstantSpacing;
        self.barcodeImageLabel.text = NSLocalizedString(@"Hide Barcode", nil);
        self.userBrightnessSetting = [[UIScreen mainScreen] brightness];
        [[UIScreen mainScreen] setBrightness:1.0];
      }
      [self.tableView endUpdates];
      break;
    }
    case CellReportIssue: {
      if (self.selectedAccount.supportEmail) {
          [[ProblemReportEmail sharedInstance]
           beginComposingTo:self.selectedAccount.supportEmail.rawValue
           presentingViewController:self
           book:nil];
          [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
          break;
      } else if (AccountsManager.sharedInstance.currentAccount.supportURL != nil) {
        BundledHTMLViewController *webController = [[BundledHTMLViewController alloc] initWithFileURL:AccountsManager.sharedInstance.currentAccount.supportURL title:AccountsManager.shared.currentAccount.name];
        webController.hidesBottomBarWhenPushed = true;
        [self.navigationController pushViewController:webController animated:YES];
        break;
      }
    }
    
    case CellKindAbout: {
      RemoteHTMLViewController *vc = [[RemoteHTMLViewController alloc]
                                      initWithURL:[self.selectedAccount.details getLicenseURL:URLTypeAcknowledgements]
                                      title:NSLocalizedString(@"About", nil)
                                      failureMessage:NSLocalizedString(@"The page could not load due to a connection error.", nil)];
      [self.navigationController pushViewController:vc animated:YES];
      break;
    }
    case CellKindPrivacyPolicy: {
      RemoteHTMLViewController *vc = [[RemoteHTMLViewController alloc]
                                      initWithURL:[self.selectedAccount.details getLicenseURL:URLTypePrivacyPolicy]
                                      title:NSLocalizedString(@"Privacy Policy", nil)
                                      failureMessage:NSLocalizedString(@"The page could not load due to a connection error.", nil)];
      [self.navigationController pushViewController:vc animated:YES];
      break;
    }
    case CellKindContentLicense: {
      RemoteHTMLViewController *vc = [[RemoteHTMLViewController alloc]
                                      initWithURL:[self.selectedAccount.details getLicenseURL:URLTypeContentLicenses]
                                      title:NSLocalizedString(@"Content Licenses", nil)
                                      failureMessage:NSLocalizedString(@"The page could not load due to a connection error.", nil)];
      [self.navigationController pushViewController:vc animated:YES];
      break;
    }
    case CellKindPasswordReset:
      [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
      [self.businessLogic resetPassword];
      break;
  }
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
      [self.tableView reloadData];
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

- (void)showSAMLLoginActivityView
{
  if (!self.idpCell) {
    return;
  }

  UIActivityIndicatorView *activityIndicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  activityIndicatorView.color = [UIColor labelColor];
  [activityIndicatorView startAnimating];

  UILabel *label = [[UILabel alloc] init];
  label.text = NSLocalizedString(@"Signing In", nil);
  label.textColor = [UIColor labelColor];
  label.font = [UIFont systemFontOfSize:16];

  UIView *linearView = [[UIView alloc] init];
  linearView.tag = sLinearViewTag;

  [linearView addSubview:activityIndicatorView];
  [linearView addSubview:label];

  [self.idpCell.contentView addSubview:linearView];

  [self.idpCell.idpName setHidden:YES];
  [self.idpCell setUserInteractionEnabled:NO];

  [activityIndicatorView autoPinEdgeToSuperviewEdge:ALEdgeLeading withInset:5.0];
  [activityIndicatorView autoAlignAxisToSuperviewAxis:ALAxisHorizontal];

  [label autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:activityIndicatorView withOffset:8.0];
  [label autoPinEdgeToSuperviewEdge:ALEdgeTrailing];

  [label autoAlignAxisToSuperviewAxis:ALAxisHorizontal];

  [linearView autoAlignAxisToSuperviewAxis: ALAxisHorizontal];
  [linearView autoAlignAxisToSuperviewAxis: ALAxisVertical];
}

- (void)removeSAMLActivityView
{
  [self.idpCell.idpName setHidden: NO];
  [self.idpCell setUserInteractionEnabled: YES];

  UIView *view = [self.idpCell.contentView viewWithTag:sLinearViewTag];
  [view removeFromSuperview];
}

- (void)didSelectBackForSignUp
{
  [self dismissViewControllerAnimated:YES completion:nil];
}

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
                                           withOffset:sVerticalMarginPadding];
        [self.usernameTextField autoConstrainAttribute:ALAttributeBottom toAttribute:ALAttributeMarginBottom
                                               ofView:[self.usernameTextField superview]
                                           withOffset:-sVerticalMarginPadding];

        if (self.businessLogic.selectedAuthentication.supportsBarcodeScanner) {
          [cell.contentView addSubview:self.barcodeScanButton];
          CGFloat rightMargin = cell.layoutMargins.right;
          if (@available(iOS 15.0, *)) {
            // contentEdgeInsets is ignored with UIButtonConfiguration, but keep for older OS
          }
          self.barcodeScanButton.contentEdgeInsets = UIEdgeInsetsMake(0, rightMargin * 2, 0, rightMargin);
          [self.barcodeScanButton autoPinEdgesToSuperviewEdgesWithInsets:UIEdgeInsetsZero excludingEdge:ALEdgeLeading];
          if (!self.usernameTextField.enabled) {
            self.barcodeScanButton.hidden = YES;
          }
        }
      }
      return cell;
    }
    case CellKindBarcodeImage:{
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;

      if (![self.businessLogic librarySupportsBarcodeDisplay]) {
        TPPLOG(@"A nonvalid library was attempting to create a barcode image.");
      } else {
        TPPBarcode *barcode = [[TPPBarcode alloc] initWithLibrary:self.selectedAccount.name];
        UIImage *barcodeImage = [barcode imageFromString:self.selectedUserAccount.authorizationIdentifier];

        if (barcodeImage) {
          self.barcodeImageView = [[UIImageView alloc] initWithImage:barcodeImage];
          self.barcodeImageLabel = [[UILabel alloc] init];
          self.barcodeTextLabel = [[UILabel alloc] init];
          self.barcodeTextLabel.text = self.selectedUserAccount.authorizationIdentifier;
          self.barcodeTextLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
          self.barcodeTextLabel.textAlignment = NSTextAlignmentCenter;
          self.barcodeImageLabel.text = NSLocalizedString(@"Show Barcode", nil);
          self.barcodeImageLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
          self.barcodeImageLabel.textColor = [TPPConfiguration mainColor];

          [cell.contentView addSubview:self.barcodeImageView];
          [cell.contentView addSubview:self.barcodeTextLabel];
          [cell.contentView addSubview:self.barcodeImageLabel];
          [self.barcodeTextLabel autoAlignAxisToSuperviewAxis:ALAxisVertical];
          [self.barcodeTextLabel autoSetDimension:ALDimensionWidth toSize:self.tableView.bounds.size.width];
          [self.barcodeImageView autoAlignAxisToSuperviewAxis:ALAxisVertical];
          [self.barcodeImageView autoSetDimension:ALDimensionWidth toSize:self.tableView.bounds.size.width];
          [NSLayoutConstraint autoSetPriority:UILayoutPriorityRequired forConstraints:^{
            // Hidden to start
            self.barcodeHeightConstraint = [self.barcodeImageView autoSetDimension:ALDimensionHeight toSize:0];
            self.barcodeTextHeightConstraint = [self.barcodeTextLabel autoSetDimension:ALDimensionHeight toSize:0];
            self.barcodeLabelSpaceConstraint = [self.barcodeImageView autoPinEdge:ALEdgeBottom toEdge:ALEdgeTop ofView:self.barcodeTextLabel withOffset:0];
            self.barcodeTextLabelSpaceConstraint = [self.barcodeTextLabel autoPinEdge:ALEdgeBottom toEdge:ALEdgeTop ofView:self.barcodeImageLabel withOffset:0];
          }];
          [self.barcodeImageView autoPinEdgeToSuperviewEdge:ALEdgeTop withInset:sConstantSpacing];
          [self.barcodeImageLabel autoAlignAxisToSuperviewAxis:ALAxisVertical];
          [NSLayoutConstraint autoSetPriority:UILayoutPriorityDefaultHigh forConstraints:^{
            [self.barcodeImageLabel autoPinEdgeToSuperviewEdge:ALEdgeBottom withInset:10.0];
          }];
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
                                       withOffset:2.0];
        [self.PINTextField autoConstrainAttribute:ALAttributeBottom toAttribute:ALAttributeMarginBottom
                                           ofView:[self.PINTextField superview]
                                       withOffset:-2.0];
      }
      return cell;
    }
    case CellKindLogInSignOut: {
      if(!self.logInSignOutCell) {
        self.logInSignOutCell = [[UITableViewCell alloc]
                                initWithStyle:UITableViewCellStyleDefault
                                reuseIdentifier:nil];
        self.logInSignOutCell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      }
      [self updateLoginLogoutCellAppearance];
      return self.logInSignOutCell;
    }
    case CellKindRegistration: {
      RegistrationCell *cell =  [RegistrationCell new];
      [cell configureWithTitle:nil body:nil buttonTitle:nil buttonAction:^{
        [self didSelectRegularSignupOnCell:cell];
      }];
      return cell;
    }
    case CellKindAgeCheck: {
      self.ageCheckCell = [[UITableViewCell alloc]
                           initWithStyle:UITableViewCellStyleDefault
                           reuseIdentifier:nil];
      
      UIImageView *accessoryView = TPPSettings.shared.userPresentedAgeCheck ? [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"CheckedCircle"]] : nil;
      accessoryView.image = [accessoryView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
      accessoryView.tintColor = [UIColor systemGreenColor];
      self.ageCheckCell.accessoryView = accessoryView;
      self.ageCheckCell.selectionStyle = TPPSettings.shared.userPresentedAgeCheck ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
      self.ageCheckCell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      self.ageCheckCell.textLabel.text = NSLocalizedString(@"Age Verification",
                                                           @"Statement that confirms if a user completed the age verification");
      return self.ageCheckCell;
    }
    case CellKindSyncButton: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      self.syncSwitch.on = self.selectedAccount.details.syncPermissionGranted;
      self.syncSwitch.enabled = true;

      cell.accessoryView = self.syncSwitch;
      [self.syncSwitch addTarget:self action:@selector(syncSwitchChanged:) forControlEvents:UIControlEventValueChanged];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      cell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      cell.textLabel.text = NSLocalizedString(@"Sync Bookmarks",
                                              @"Title for switch to turn on or off syncing.");
      return cell;
    }
    case CellReportIssue: {
      UITableViewCell *cell = [[UITableViewCell alloc]
                               initWithStyle:UITableViewCellStyleDefault
                               reuseIdentifier:nil];
      cell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      cell.textLabel.text = NSLocalizedString(@"Report an Issue", nil);
      return cell;
    }
    case CellKindAbout: {
      UITableViewCell *cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      cell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      cell.textLabel.text = [NSString stringWithFormat:@"About %@",self.selectedAccount.name];
      cell.hidden = ([self.selectedAccount.details getLicenseURL:URLTypeAcknowledgements]) ? NO : YES;
      return cell;
    }
    case CellKindPrivacyPolicy: {
      UITableViewCell *cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      cell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      cell.textLabel.text = NSLocalizedString(@"Privacy Policy", nil);
      cell.hidden = ([self.selectedAccount.details getLicenseURL:URLTypePrivacyPolicy]) ? NO : YES;
      return cell;
    }
    case CellKindContentLicense: {
      UITableViewCell *cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      cell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      cell.textLabel.text = NSLocalizedString(@"Content Licenses", nil);
      cell.hidden = ([self.selectedAccount.details getLicenseURL:URLTypeContentLicenses]) ? NO : YES;
      return cell;
    }
    case CellKindAdvancedSettings: {
      UITableViewCell *cell = [[UITableViewCell alloc]
                               initWithStyle:UITableViewCellStyleDefault
                               reuseIdentifier:nil];
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      cell.textLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleBody];
      cell.textLabel.text = NSLocalizedString(@"Advanced", nil);
      return cell;
    }
    case CellKindPasswordReset:
      return [self createPasswordResetCell];
  }
}

- (UITableViewCell *)createPasswordResetCell {
  UITableViewCell *cell = [[UITableViewCell alloc] init];
  cell.textLabel.text = NSLocalizedString(@"Forgot your password?", "Password Reset");
  return cell;
}

- (NSInteger)numberOfSectionsInTableView:(__attribute__((unused)) UITableView *)tableView
{
  return self.businessLogic.isAuthenticationDocumentLoading ? 0 : self.tableData.count;
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

- (CGFloat)tableView:(__unused UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
  if (section == sSection0AccountInfo) {
    return UITableViewAutomaticDimension;
  }
  return 0;
}
- (CGFloat)tableView:(__unused UITableView *)tableView heightForFooterInSection:(__unused NSInteger)section
{
  if ((section == sSection0AccountInfo && [self.businessLogic shouldShowEULALink]) ||
      (section == sSection1Sync && [self.businessLogic shouldShowSyncButton])) {
    return UITableViewAutomaticDimension;
  }
  return 0;
}
-(CGFloat)tableView:(__unused UITableView *)tableView estimatedHeightForHeaderInSection:(NSInteger)section
{
  if (section == sSection0AccountInfo) {
    return 80;
  }
  return 0;
}
- (CGFloat)tableView:(__unused UITableView *)tableView estimatedHeightForFooterInSection:(__unused NSInteger)section
{
  if ((section == sSection0AccountInfo && [self.businessLogic shouldShowEULALink]) ||
      (section == sSection1Sync && [self.businessLogic shouldShowSyncButton])) {
    return 44;
  }
  return 0;
}

- (CGFloat)tableView:(__unused UITableView *)tableView estimatedHeightForRowAtIndexPath:(__unused NSIndexPath *)indexPath
{
  return 44;
}
-(CGFloat)tableView:(__unused UITableView *)tableView heightForRowAtIndexPath:(__unused NSIndexPath *)indexPath
{
  return UITableViewAutomaticDimension;
}

- (void) setupHeaderView
{
  UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.frame.size.width, 100)];
  UIView *containerView = [[UIView alloc] init];
  
  UIView *imageViewHolder = [[UIView alloc] init];
  [imageViewHolder autoSetDimension:ALDimensionHeight toSize:50.0];
  [imageViewHolder autoSetDimension:ALDimensionWidth toSize:50.0];

  UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 75, 75)];
  imageView.image = self.selectedAccount.logo;
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
  titleLabel.text = self.selectedAccount.name;
  [containerView addSubview: titleLabel];

  self.tableView.tableHeaderView = headerView;

  [containerView autoAlignAxisToSuperviewAxis:ALAxisHorizontal];
  [containerView autoAlignAxisToSuperviewAxis:ALAxisVertical];
  [containerView autoPinEdgesToSuperviewMarginsWithInsets:UIEdgeInsetsMake(10, 10, 10, 10)];
  [imageViewHolder autoPinEdgesToSuperviewMarginsExcludingEdge:ALEdgeTrailing];
  [titleLabel autoPinEdgesToSuperviewMarginsExcludingEdge:ALEdgeLeading];
  [imageViewHolder autoPinEdge:ALEdgeTrailing toEdge:ALEdgeLeading ofView:titleLabel withOffset:-10];
}

- (UIView *)tableView:(UITableView *)__unused tableView viewForFooterInSection:(NSInteger)section
{
  // something's wrong, it gets called every refresh cycle when scrolling
  if ((section == sSection0AccountInfo && [self.businessLogic shouldShowEULALink]) ||
      (section == sSection1Sync && [self.businessLogic shouldShowSyncButton])) {

    UIView *container = [[UIView alloc] init];
    container.preservesSuperviewLayoutMargins = YES;
    UILabel *footerLabel = [[UILabel alloc] init];
    footerLabel.font = [UIFont customFontForTextStyle:UIFontTextStyleCaption1];
    footerLabel.numberOfLines = 0;
    footerLabel.userInteractionEnabled = YES;

    NSMutableAttributedString *eulaString;
    if (section == sSection0AccountInfo) {
      [footerLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showEULA)]];

      NSDictionary *linkAttributes = @{ NSForegroundColorAttributeName :
                                          [UIColor colorWithRed:0.05 green:0.4 blue:0.65 alpha:1.0],
                                        NSUnderlineStyleAttributeName :
                                          @(NSUnderlineStyleSingle) };
      eulaString = [[NSMutableAttributedString alloc]
                    initWithString:NSLocalizedString(@"By signing in, you agree to the End User License Agreement.", nil) attributes:linkAttributes];
    } else { // sync section
      NSDictionary *attrs;
      attrs = @{ NSForegroundColorAttributeName : [UIColor defaultLabelColor] };
      eulaString = [[NSMutableAttributedString alloc]
                    initWithString:NSLocalizedString(@"Save your reading position and bookmarks to all your other devices.",
                                                     @"Explain to the user they can save their bookmarks in the cloud across all their devices.")
                    attributes:attrs];
    }
    footerLabel.attributedText = eulaString;

    [container addSubview:footerLabel];
    [footerLabel autoPinEdgeToSuperviewMargin:ALEdgeLeft];
    [footerLabel autoPinEdgeToSuperviewMargin:ALEdgeRight];
    [footerLabel autoPinEdgeToSuperviewEdge:ALEdgeTop withInset:8.0];
    [footerLabel autoPinEdgeToSuperviewEdge:ALEdgeBottom withInset:16.0 relation:NSLayoutRelationGreaterThanOrEqual];

    if (section == sSection0AccountInfo) {
      self.accountInfoFooterView = container;
    } else if (section == sSection1Sync) {
      self.syncFooterView = container;
    }

    return container;
  }
  return nil;
}

#pragma mark - Text Input

- (void)textFieldsDidChange
{
  [self updateLoginLogoutCellAppearance];
}

- (void)keyboardDidShow:(NSNotification *const)notification
{
  // This nudges the scroll view up slightly so that the log in button is clearly visible even on
  // older 3:2 iPhone displays.
  [NSOperationQueue.mainQueue addOperationWithBlock:^{
    if ((UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) ||
        (self.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact &&
         self.traitCollection.verticalSizeClass == UIUserInterfaceSizeClassCompact)) {
      
      if (self.logInSignOutCell && ![self.tableView.visibleCells containsObject:self.logInSignOutCell]) {
        NSIndexPath *indexPath = [self.tableView indexPathForCell:self.logInSignOutCell];
        if (indexPath) {
          [self.tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
        }
      }
    }
  }];
}

#pragma mark - PIN Show/Hide

- (void)PINShowHideSelected
{
  if(self.PINTextField.text.length > 0 && self.PINTextField.secureTextEntry) {
    LAContext *const context = [[LAContext alloc] init];
    if([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:NULL]) {
      [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
              localizedReason:NSLocalizedString(@"Authenticate to reveal your PIN.", nil)
                        reply:^(BOOL success, NSError *_Nullable error) {
        if(success) {
          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [self togglePINShowHideState];
          }];
        } else {
          [TPPErrorLogger logError:error
                            summary:@"Error while trying to show/hide the PIN"
                           metadata:nil];
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

  // LAPolicyDeviceOwnerAuthentication is only on iOS >= 9.0
  if([NSProcessInfo processInfo].operatingSystemVersion.majorVersion >= 9) {
    LAContext *const context = [[LAContext alloc] init];
    if([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:NULL]) {
      self.PINTextField.rightView.hidden = NO;
    }
  }
}

#pragma mark - UI update

- (void)accountDidChange
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    if(self.selectedUserAccount.hasCredentials) {
      self.usernameTextField.text = self.selectedUserAccount.barcode;
      self.usernameTextField.enabled = NO;
      self.usernameTextField.textColor = [UIColor grayColor];
      self.PINTextField.text = self.selectedUserAccount.PIN;
      self.PINTextField.textColor = [UIColor grayColor];
      self.barcodeScanButton.hidden = YES;
    } else {
      self.usernameTextField.text = nil;
      self.usernameTextField.enabled = YES;
      self.usernameTextField.textColor = [UIColor defaultLabelColor];
      self.PINTextField.text = nil;
      self.PINTextField.textColor = [UIColor defaultLabelColor];
      if (self.businessLogic.selectedAuthentication.supportsBarcodeScanner) {
        self.barcodeScanButton.hidden = NO;
      }
    }
    
    [self setupTableData];

    [self updateLoginLogoutCellAppearance];
  }];
}

- (void)updateLoginLogoutCellAppearance
{
  if([self.selectedUserAccount hasCredentials]) {
    // check if we have added the activity view for signing out
    if ([self.logInSignOutCell.contentView viewWithTag:sLinearViewTag] != nil) {
      return;
    }

    self.logInSignOutCell.textLabel.text = NSLocalizedString(@"Sign out", @"Title for sign out action");
    self.logInSignOutCell.textLabel.textAlignment = NSTextAlignmentCenter;
    self.logInSignOutCell.textLabel.textColor = [TPPConfiguration mainColor];
    self.logInSignOutCell.userInteractionEnabled = YES;
  } else {
    self.logInSignOutCell.textLabel.text = NSLocalizedString(@"Sign in", nil);
    self.logInSignOutCell.textLabel.textAlignment = NSTextAlignmentLeft;
    BOOL const barcodeHasText = [self.usernameTextField.text
                                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length;
    BOOL const pinHasText = [self.PINTextField.text
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length;
    BOOL const pinIsNotRequired = self.businessLogic.selectedAuthentication.pinKeyboard == LoginKeyboardNone;
    BOOL const oauthLogin = self.businessLogic.selectedAuthentication.isOauth;
    if((barcodeHasText && pinHasText) || (barcodeHasText && pinIsNotRequired) || oauthLogin) {
      self.logInSignOutCell.userInteractionEnabled = YES;
      self.logInSignOutCell.textLabel.textColor = [TPPConfiguration mainColor];
    } else {
      self.logInSignOutCell.userInteractionEnabled = NO;
      self.logInSignOutCell.textLabel.textColor = [UIColor systemGray2Color];
    }
  }
}

- (void)setActivityTitleWithText:(NSString *)text
{
  // since we are adding a subview to self.logInSignOutCell.contentView, there
  // is no point in continuing if for some reason logInSignOutCell is nil.
  if (self.logInSignOutCell.contentView == nil) {
    return;
  }

  // check if we already added the activity view
  if ([self.logInSignOutCell.contentView viewWithTag:sLinearViewTag] != nil) {
    return;
  }

  UIActivityIndicatorView *aiv = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  aiv.color = [UIColor labelColor];

  UIActivityIndicatorView *const activityIndicatorView = aiv;
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
  
  self.logInSignOutCell.textLabel.text = nil;
  [self.logInSignOutCell.contentView addSubview:linearView];
  [linearView autoCenterInSuperview];
}

- (void)removeActivityTitle
{
  UIView *view = [self.logInSignOutCell.contentView viewWithTag:sLinearViewTag];
  [view removeFromSuperview];
  [self updateLoginLogoutCellAppearance];
}

#pragma mark -

- (void)scanLibraryCard
{
#ifdef OPENEBOOKS
  __auto_type auth = self.businessLogic.selectedAuthentication;
  [TPPErrorLogger logErrorWithCode:NYPLErrorCodeAppLogicInconsistency
                            summary:@"Barcode button was displayed"
                           metadata:@{
                             @"Supports barcode display": @(auth.supportsBarcodeDisplay) ?: @"N/A",
                             @"Supports barcode scanner": @(auth.supportsBarcodeScanner) ?: @"N/A",
                             @"Context": @"Settings tab"
                           }];
#else
  [TPPBarcode presentScannerWithCompletion:^(NSString * _Nullable resultString) {
    if (resultString) {
      self.usernameTextField.text = resultString;
      [self.PINTextField becomeFirstResponder];
      self.loggingInAfterBarcodeScan = YES;
    }
  }];
#endif
}

- (void)showEULA
{
  UIViewController *eulaViewController = [[TPPSettingsEULAViewController alloc] initWithAccount:self.selectedAccount];
  UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:eulaViewController];
  [self.navigationController presentViewController:navVC animated:YES completion:nil];
}

- (void)confirmAgeChange:(void (^)(BOOL))completion
{
  UIAlertController *alertCont = [UIAlertController
                                    alertControllerWithTitle:NSLocalizedString(@"Age Verification", @"An alert title indicating the user needs to verify their age")
                                    message:NSLocalizedString(@"If you are under 13, all content downloaded to My Books will be removed.",
                                                              @"An alert message warning the user they will lose their downloaded books if they continue.")
                                    preferredStyle:UIAlertControllerStyleAlert];
  
  [alertCont addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"Under 13", comment: @"A button title indicating an age range")
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * _Nonnull __unused action) {
                                                 if (completion) { completion(YES); }
                                               }]];
  
  [alertCont addAction: [UIAlertAction actionWithTitle:NSLocalizedString(@"13 or Older", comment: @"A button title indicating an age range")
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction * _Nonnull __unused action) {
                                                 if (completion) { completion(NO); }
                                               }]];

  if ([self.selectedAccountId isEqualToString:[AccountsManager TPPAccountUUIDs][2]]) {
    [TPPAlertUtils presentFromViewControllerOrNilWithAlertController:alertCont viewController:nil animated:YES completion:nil];
  }
}

#pragma mark - Bookmark Syncing

- (void)syncSwitchChanged:(UISwitch*)sender
{
  self.syncSwitch.on = sender.on;
  self.selectedAccount.details.syncPermissionGranted = sender.on;
}

#pragma mark - UIApplication callbacks

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
    dispatch_async(dispatch_get_main_queue(), ^{
    [self setActivityTitleWithText:NSLocalizedString(@"Verifying", nil)];
    });
  }
}

- (void)businessLogicDidCancelSignIn:(TPPSignInBusinessLogic *)businessLogic
{
  if (businessLogic.selectedAuthentication.isSaml) {
    [self removeSAMLActivityView];
  }
}

- (void) businessLogic:(TPPSignInBusinessLogic *)businessLogic
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

- (void)businessLogicDidCompleteSignIn:(TPPSignInBusinessLogic *)businessLogic
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    [self removeActivityTitle];
    [self removeSAMLActivityView];
  }];
}

- (void)   businessLogic:(TPPSignInBusinessLogic *)logic
didEncounterSignOutError:(NSError *)error
      withHTTPStatusCode:(NSInteger)statusCode
{
  [self showLogoutAlertWithError:error responseCode:statusCode];
  [self removeActivityTitle];
  [self removeSAMLActivityView];
}

- (void)businessLogicWillSignOut:(TPPSignInBusinessLogic *)businessLogic
{
#if defined(FEATURE_DRM_CONNECTOR)
  [self setActivityTitleWithText:NSLocalizedString(@"Signing out", nil)];
#endif
}

- (void)businessLogicDidFinishDeauthorizing:(TPPSignInBusinessLogic *)businessLogic
{
  [self removeActivityTitle];
  [self setupTableData];
}

@end
