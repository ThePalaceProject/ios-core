#import "TPPTenPrintCoverView.h"

@interface TPPTenPrintCoverView (NYPLImageAdditions)

// Must be called on the main thread.
+ (UIImage *)imageForBook:(TPPBook *const)book;

@end
