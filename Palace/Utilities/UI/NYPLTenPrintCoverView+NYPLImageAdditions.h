#import "NYPLTenPrintCoverView.h"
#import "Palace-Swift.h"

@interface NYPLTenPrintCoverView (NYPLImageAdditions)

// Must be called on the main thread.
+ (UIImage *)imageForBook:(TPPBook *const)book;

@end
