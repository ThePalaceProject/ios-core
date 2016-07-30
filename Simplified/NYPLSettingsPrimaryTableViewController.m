#import "NYPLConfiguration.h"
#import "NYPLSettings.h"

#import "NYPLSettingsPrimaryTableViewController.h"

static NYPLSettingsPrimaryTableViewControllerItem
SettingsItemFromIndexPath(NSIndexPath *const indexPath)
{
  switch(indexPath.section) {
    case 0:
      switch(indexPath.row) {
        case 0:
          return NYPLSettingsPrimaryTableViewControllerItemAccount;
        default:
          @throw NSInvalidArgumentException;
      }
    case 1:
      switch (indexPath.row) {
        case 0:
          return NYPLSettingsPrimaryTableViewControllerItemHelpStack;
        default:
          @throw NSInvalidArgumentException;
      }
    case 2:
      switch(indexPath.row) {
        case 0:
          return NYPLSettingsPrimaryTableViewControllerItemAbout;
        case 1:
          return NYPLSettingsPrimaryTableViewControllerItemCredits;
        case 2:
          return NYPLSettingsPrimaryTableViewControllerItemEULA;
        case 3:
          return NYPLSettingsPrimaryTableViewControllerItemPrivacyPolicy;
        default:
          @throw NSInvalidArgumentException;
      }
    case 3:
      switch (indexPath.row) {
        case 0:
          return NYPLSettingsPrimaryTableViewControllerItemCustomFeedURL;
        default:
          @throw NSInvalidArgumentException;
      }
    default:
      @throw NSInvalidArgumentException;
  }
}

NSIndexPath *NYPLSettingsPrimaryTableViewControllerIndexPathFromSettingsItem(
  const NYPLSettingsPrimaryTableViewControllerItem settingsItem)
{
  switch(settingsItem) {
    case NYPLSettingsPrimaryTableViewControllerItemAbout:
      return [NSIndexPath indexPathForRow:0 inSection:2];
    case NYPLSettingsPrimaryTableViewControllerItemAccount:
      return [NSIndexPath indexPathForRow:0 inSection:0];
    case NYPLSettingsPrimaryTableViewControllerItemCredits:
      return [NSIndexPath indexPathForRow:1 inSection:2];
    case NYPLSettingsPrimaryTableViewControllerItemEULA:
      return [NSIndexPath indexPathForRow:2 inSection:2];
    case NYPLSettingsPrimaryTableViewControllerItemPrivacyPolicy:
      return [NSIndexPath indexPathForRow:3 inSection:2];
    case NYPLSettingsPrimaryTableViewControllerItemHelpStack:
      return [NSIndexPath indexPathForRow:0 inSection:1];
    case NYPLSettingsPrimaryTableViewControllerItemCustomFeedURL:
      return [NSIndexPath indexPathForRow:0 inSection:3];
  }
}

@interface NYPLSettingsPrimaryTableViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UILabel *infoLabel;
@end

@implementation NYPLSettingsPrimaryTableViewController

#pragma mark NSObject

- (instancetype)init
{
  self = [super initWithStyle:UITableViewStyleGrouped];
  if(!self) return nil;
  
  self.title = NSLocalizedString(@"More", nil);
  
  self.clearsSelectionOnViewWillAppear = NO;
  
  return self;
}

#pragma mark UIViewController

- (void)viewDidLoad
{
  [super viewDidLoad];
  
  self.view.backgroundColor = [NYPLConfiguration backgroundColor];

  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(revealCustomFeedUrl)];
  tap.numberOfTapsRequired = 7;
  
  [[self.navigationController.navigationBar.subviews objectAtIndex:1] setUserInteractionEnabled:YES];
  [[self.navigationController.navigationBar.subviews objectAtIndex:1] addGestureRecognizer:tap];
}

- (void)revealCustomFeedUrl
{
  [NYPLConfiguration customFeedEnabled:YES];
  
  [self.tableView reloadData];
}

#pragma mark UITableViewDelegate

- (void)tableView:(__attribute__((unused)) UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *const)indexPath
{
  [self.delegate settingsPrimaryTableViewController:self
                                      didSelectItem:SettingsItemFromIndexPath(indexPath)];
}

- (CGFloat)tableView:(__unused UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
  NSInteger sectionCount = [self numberOfSectionsInTableView:self.tableView];
  if (section == (sectionCount-1))
    return 45.0;
  return 0;
}

- (UIView *)tableView:(__unused UITableView *)tableView viewForFooterInSection:(NSInteger)section
{
  NSInteger sectionCount = [self numberOfSectionsInTableView:self.tableView];
  if (section == (sectionCount-1)) {
    if (self.infoLabel == nil) {
      self.infoLabel = [[UILabel alloc] init];
      [self.infoLabel setFont:[UIFont systemFontOfSize:12]];
      NSString *productName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
      NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
      NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey];
      self.infoLabel.text = [NSString stringWithFormat:@"%@ version %@ (%@)", productName, version, build];
      self.infoLabel.textAlignment = NSTextAlignmentCenter;
      [self.infoLabel sizeToFit];
    }
    return self.infoLabel;
  }
  return nil;
}

#pragma mark UITableViewDataSource

- (UITableViewCell *)tableView:(__attribute__((unused)) UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *const)indexPath
{
  switch(SettingsItemFromIndexPath(indexPath)) {
    case NYPLSettingsPrimaryTableViewControllerItemAbout: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.textLabel.text = NSLocalizedString(@"About", nil);
      cell.textLabel.font = [UIFont systemFontOfSize:17];
      if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      }
      return cell;
    }
    case NYPLSettingsPrimaryTableViewControllerItemAccount: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.textLabel.text = NSLocalizedString(@"Library Card", nil);
      cell.textLabel.font = [UIFont systemFontOfSize:17];
      if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      }
      return cell;
    }
    case NYPLSettingsPrimaryTableViewControllerItemCredits: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.textLabel.text = NSLocalizedString(@"Acknowledgements", nil);
      cell.textLabel.font = [UIFont systemFontOfSize:17];
      if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      }
      return cell;
    }
    case NYPLSettingsPrimaryTableViewControllerItemEULA: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.textLabel.text = NSLocalizedString(@"EULA", nil);
      cell.textLabel.font = [UIFont systemFontOfSize:17];
      if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      }
      return cell;
    }
    case NYPLSettingsPrimaryTableViewControllerItemPrivacyPolicy: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.textLabel.text = NSLocalizedString(@"PrivacyPolicy", nil);
      cell.textLabel.font = [UIFont systemFontOfSize:17];
      if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      }
      return cell;
    }
    case NYPLSettingsPrimaryTableViewControllerItemHelpStack: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      cell.textLabel.text = NSLocalizedString(@"Help", nil);
      cell.textLabel.font = [UIFont systemFontOfSize:17];
      if(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      }
      return cell;
    }
    case NYPLSettingsPrimaryTableViewControllerItemCustomFeedURL: {
      UITableViewCell *const cell = [[UITableViewCell alloc]
                                     initWithStyle:UITableViewCellStyleDefault
                                     reuseIdentifier:nil];
      UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(20, 0, cell.frame.size.width-20, cell.frame.size.height)];
      field.delegate = self;
      field.text = [NYPLSettings sharedSettings].customMainFeedURL.absoluteString;
      field.borderStyle = UITextBorderStyleRoundedRect;
      field.placeholder = @"Enter a custom HTTP OPDS URL";
      field.keyboardType = UIKeyboardTypeURL;
      field.returnKeyType = UIReturnKeyDone;
      field.spellCheckingType = UITextSpellCheckingTypeNo;
      field.autocorrectionType = UITextAutocorrectionTypeNo;
      field.autocapitalizationType = UITextAutocapitalizationTypeNone;
      [cell.contentView addSubview:field];
      return cell;
    }
  }
}

- (NSInteger)numberOfSectionsInTableView:(__attribute__((unused)) UITableView *)tableView
{
  if ([NYPLSettings sharedSettings].customMainFeedURL.absoluteString != nil)
  {
    [NYPLConfiguration customFeedEnabled:true];
  }
  return 3 + !![NYPLConfiguration customFeedEnabled];
}

-(BOOL)tableView:(__attribute__((unused)) UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
  if (SettingsItemFromIndexPath(indexPath) == NYPLSettingsPrimaryTableViewControllerItemCustomFeedURL) {
    return true;
  }
  return false;
}

- (void)exitApp
{
  UIAlertController *alertViewController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Restart", nil)
                                                                               message:NSLocalizedString(@"You need to restart the app to change modes. Select Exit and then restart the App from the home screen.", nil)
                                                                        preferredStyle:UIAlertControllerStyleAlert];
  [alertViewController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Not Now", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil]];
  [alertViewController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Exit App", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__attribute__((unused)) UIAlertAction * action) {
                                                          exit(0);
                                                        }]];
  [self presentViewController:alertViewController animated:YES completion:nil];
}

-(void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
  
  if (SettingsItemFromIndexPath(indexPath) == NYPLSettingsPrimaryTableViewControllerItemCustomFeedURL && editingStyle == UITableViewCellEditingStyleDelete) {
    
    [NYPLConfiguration customFeedEnabled:false];
    [NYPLSettings sharedSettings].customMainFeedURL = nil;
    
    [tableView reloadData];
    
    [self exitApp];
    
  }
}

- (NSInteger)tableView:(__attribute__((unused)) UITableView *)tableView
 numberOfRowsInSection:(NSInteger const)section
{
  switch(section) {
    case 2:
      return 4;
    case 0: case 1: case 3:
      return 1;
    default:
      @throw NSInternalInconsistencyException;
  }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *const)textField
{
  [textField resignFirstResponder];
  
  NSString *const feed = [textField.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
  
  if(feed.length) {
    [NYPLSettings sharedSettings].customMainFeedURL = [NSURL URLWithString:feed];
  } else {
    [NYPLSettings sharedSettings].customMainFeedURL = nil;
  }
  
  return YES;
}
-(void)textFieldDidEndEditing:(__attribute__((unused)) UITextField *)textField
{
  [self exitApp];
}

@end
