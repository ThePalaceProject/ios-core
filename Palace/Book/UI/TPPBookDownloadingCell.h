#import "TPPBookCell.h"
//#import "Palace-Swift.h"

@class TPPBookDownloadingCell;
@class TPPBook;

@protocol TPPBookDownloadingCellDelegate

- (void)didSelectCancelForBookDownloadingCell:(TPPBookDownloadingCell *)cell;

@end

@interface TPPBookDownloadingCell : TPPBookCell

@property (nonatomic) TPPBook *book;
@property (nonatomic, weak) id<TPPBookDownloadingCellDelegate> delegate;
@property (nonatomic) double downloadProgress;

@end
