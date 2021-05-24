#import "TPPBookCell.h"

@class TPPBook;
@class TPPBookDownloadFailedCell;

@protocol TPPBookDownloadFailedCellDelegate

- (void)didSelectCancelForBookDownloadFailedCell:(TPPBookDownloadFailedCell *)cell;
- (void)didSelectTryAgainForBookDownloadFailedCell:(TPPBookDownloadFailedCell *)cell;

@end

@interface TPPBookDownloadFailedCell : TPPBookCell

@property (nonatomic) TPPBook *book;
@property (nonatomic, weak) id<TPPBookDownloadFailedCellDelegate> delegate;

@end
