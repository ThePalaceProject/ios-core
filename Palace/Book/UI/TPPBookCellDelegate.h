@import PalaceAudiobookToolkit;

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
@property (nonatomic) TPPBook *book;
@property (nonatomic) bool isSyncing;
@property (nonatomic) NSDate *lastServerUpdate;
@property (nonatomic, weak) UIViewController *audiobookViewController;
@property (nonatomic) DefaultAudiobookManager *manager;
@property (nonatomic) NSTimeInterval previousPlayheadOffset;

- (void) startLoading:(UIViewController *)hostViewController;
- (void) stopLoading;
- (void)presentLocationRecoveryError:(NSError *)error;

@end
