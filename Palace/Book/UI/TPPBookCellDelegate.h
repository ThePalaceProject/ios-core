#import "TPPBookDownloadFailedCell.h"
#import "TPPBookDownloadingCell.h"
#import "TPPBookButtonsView.h"

/* This class implements a shared delegate that performs all of its duties via the shared registry,
shared cover registry, shared download center, et cetera. */
@interface TPPBookCellDelegate : NSObject
  <TPPBookButtonsDelegate, TPPBookDownloadFailedCellDelegate, TPPBookDownloadingCellDelegate>

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

+ (instancetype)sharedDelegate;

@end
