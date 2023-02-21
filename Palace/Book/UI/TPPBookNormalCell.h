#import "TPPBookCell.h"
#import "TPPBookButtonsState.h"
#import "Palace-Swift.h"

@class TPPBookNormalCell;
@class TPPBook;

@protocol TPPBookButtonsDelegate;

@interface TPPBookNormalCell : TPPBookCell

@property (nonatomic) TPPBook *book;
@property (nonatomic) TPPBookButtonsState state;
@property (nonatomic, weak) id<TPPBookButtonsDelegate> delegate;

@property (nonatomic) UIImageView *cover;

@end
