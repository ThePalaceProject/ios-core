#import "TPPSettingsPrimaryTableViewController.h"

#import "TPPSettingsPrimaryNavigationController.h"

@interface TPPSettingsPrimaryNavigationController ()

@property (nonatomic) TPPSettingsPrimaryTableViewController *tableViewController;

@end

@implementation TPPSettingsPrimaryNavigationController

#pragma mark NSObject

- (instancetype)init
{
  TPPSettingsPrimaryTableViewController *const tableViewController =
    [[TPPSettingsPrimaryTableViewController alloc] init];
  
  self = [super initWithRootViewController:tableViewController];
  if(!self) return nil;
  
  self.tableViewController = tableViewController;
  
  return self;
}

#pragma mark -

- (TPPSettingsPrimaryTableViewController *)primaryTableViewController
{
  return self.tableViewController;
}

@end
