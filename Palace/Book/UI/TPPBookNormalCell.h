#import "TPPBookCell.h"
#import "TPPBookButtonsState.h"

@class TPPBook;
@class TPPBookNormalCell;
@protocol TPPBookButtonsDelegate;

@interface TPPBookNormalCell : TPPBookCell

@property (nonatomic) TPPBook *book;
@property (nonatomic) TPPBookButtonsState state;
@property (nonatomic, weak) id<TPPBookButtonsDelegate> delegate;

@property (nonatomic) UIImageView *cover;

@end
