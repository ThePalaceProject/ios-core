//
//  TPPLibraryNavigationController.m
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/18/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#import "Palace-Swift.h"

#if defined(FEATURE_DRM_CONNECTOR)
#import <ADEPT/ADEPT.h>
#endif

#import "TPPLibraryNavigationController.h"
#import "TPPBookRegistry.h"
#import "TPPRootTabBarController.h"
#import "TPPCatalogNavigationController.h"

#ifdef SIMPLYE
// TODO: SIMPLY-3053 this #ifdef can be removed once this ticket is done
#import "TPPSettingsPrimaryTableViewController.h"
#endif


@interface TPPLibraryNavigationController ()

@end

@implementation TPPLibraryNavigationController

#ifdef SIMPLYE
- (void)setNavigationLeftBarButtonForVC:(UIViewController *)vc
{
  vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
                                         initWithImage:[UIImage imageNamed:@"Catalog"] style:(UIBarButtonItemStylePlain)
                                         target:self
                                         action:@selector(switchLibrary)];
  vc.navigationItem.leftBarButtonItem.accessibilityLabel = NSLocalizedString(@"AccessibilitySwitchLibrary", nil);
}

// for converting this to Swift, see https://bit.ly/3mM9QoH
- (void)switchLibrary
{
  UIViewController *viewController = self.visibleViewController;

  UIAlertControllerStyle style;
  if (viewController && viewController.navigationItem.leftBarButtonItem) {
    style = UIAlertControllerStyleActionSheet;
  } else {
    style = UIAlertControllerStyleAlert;
  }

  UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Find Your Library", nil) message:nil preferredStyle:style];
  alert.popoverPresentationController.barButtonItem = viewController.navigationItem.leftBarButtonItem;
  alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionUp;

  NSArray *accounts = [[TPPSettings sharedSettings] settingsAccountsList];

  for (int i = 0; i < (int)accounts.count; i++) {
    Account *account = [[AccountsManager sharedInstance] account:accounts[i]];
    if (!account) {
      continue;
    }

    [alert addAction:[UIAlertAction actionWithTitle:account.name style:(UIAlertActionStyleDefault) handler:^(__unused UIAlertAction *_Nonnull action) {

      BOOL workflowsInProgress;
#if defined(FEATURE_DRM_CONNECTOR)
      if ([AdobeCertificate.defaultCertificate hasExpired] == NO) {
        workflowsInProgress = ([NYPLADEPT sharedInstance].workflowsInProgress || [TPPBookRegistry sharedRegistry].syncing == YES);
      } else {
        workflowsInProgress = ([TPPBookRegistry sharedRegistry].syncing == YES);
      }
#else
      workflowsInProgress = ([TPPBookRegistry sharedRegistry].syncing == YES);
#endif

      if (workflowsInProgress) {
        [self presentViewController:[TPPAlertUtils
                                     alertWithTitle:@"Please Wait"
                                     message:@"Please wait a moment before switching library accounts."]
                           animated:YES
                         completion:nil];
      } else {
        [[TPPBookRegistry sharedRegistry] save];
        [self updateCatalogFeedSettingCurrentAccount:account];
      }
    }]];
  }

  [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Manage Accounts", nil) style:(UIAlertActionStyleDefault) handler:^(__unused UIAlertAction *_Nonnull action) {
    NSUInteger tabCount = [[[TPPRootTabBarController sharedController] viewControllers] count];
    UISplitViewController *splitViewVC = [[[TPPRootTabBarController sharedController] viewControllers] lastObject];
    UINavigationController *masterNavVC = [[splitViewVC viewControllers] firstObject];
    [masterNavVC popToRootViewControllerAnimated:NO];
    [[TPPRootTabBarController sharedController] setSelectedIndex:tabCount-1];
    TPPSettingsPrimaryTableViewController *tableVC = [[masterNavVC viewControllers] firstObject];
    [tableVC.delegate settingsPrimaryTableViewController:tableVC didSelectItem:NYPLSettingsPrimaryTableViewControllerItemAccount];
  }]];

  [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:(UIAlertActionStyleCancel) handler:nil]];

  [[TPPRootTabBarController sharedController] safelyPresentViewController:alert animated:YES completion:nil];
}

- (void)updateCatalogFeedSettingCurrentAccount:(Account *)account
{
  [AccountsManager shared].currentAccount = account;
  TPPCatalogNavigationController * catalog = (TPPCatalogNavigationController*)[TPPRootTabBarController sharedController].viewControllers[0];
  [catalog updateFeedAndRegistryOnAccountChange];

  UIViewController *visibleVC = self.visibleViewController;
  visibleVC.navigationItem.title = [AccountsManager shared].currentAccount.name;
}
#endif

@end
