#import "TPPBookButtonsState.h"
#import "Palace-Swift.h"
@class TPPBook;

@interface TPPBookDetailNormalView : UIView

@property (nonatomic) TPPBookButtonsState state;
@property (nonatomic, weak) TPPBook *book;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;

@end
