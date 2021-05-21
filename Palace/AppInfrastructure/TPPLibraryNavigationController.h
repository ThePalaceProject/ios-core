//
//  TPPLibraryNavigationController.h
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/18/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

#import <UIKit/UIKit.h>

@class Account;

@interface TPPLibraryNavigationController : UINavigationController

#ifdef SIMPLYE
- (void)setNavigationLeftBarButtonForVC:(UIViewController *)vc;
- (void)switchLibrary;
- (void)updateCatalogFeedSettingCurrentAccount:(Account *)account;
#endif

@end

