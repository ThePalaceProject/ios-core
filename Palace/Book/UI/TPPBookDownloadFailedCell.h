#import "TPPBookCell.h"
#import "Palace-Swift.h"

@class TPPBookDownloadFailedCell;
@class TPPBook;

@protocol TPPBookDownloadFailedCellDelegate

- (void)didSelectCancelForBookDownloadFailedCell:(TPPBookDownloadFailedCell *)cell;
- (void)didSelectTryAgainForBookDownloadFailedCell:(TPPBookDownloadFailedCell *)cell;

@end

@interface TPPBookDownloadFailedCell : TPPBookCell

@property (nonatomic) TPPBook *book;
@property (nonatomic, weak) id<TPPBookDownloadFailedCellDelegate> delegate;

@end
