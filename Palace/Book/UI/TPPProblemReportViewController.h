//
//  TPPProblemReportViewController.h
//  The Palace Project
//
//  Created by Sam Tarakajian on 10/29/15.
//  Copyright © 2015 NYPL Labs. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "Palace-Swift.h"

@class TPPProblemReportViewController;
@class TPPBook;

@protocol TPPProblemReportViewControllerDelegate
- (void)problemReportViewController:(TPPProblemReportViewController *)problemReportViewController didSelectProblemWithType:(NSString *)type;
@end

@interface TPPProblemReportViewController : UIViewController
@property (nonatomic, strong) TPPBook *book;
@property (nonatomic, weak) id<TPPProblemReportViewControllerDelegate> delegate;
@end
