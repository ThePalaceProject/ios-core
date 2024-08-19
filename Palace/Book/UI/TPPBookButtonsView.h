#import "TPPBookButtonsState.h"

@class TPPBook;
@class TPPBookButtonsView;
@class TPPBookDetailDownloadFailedView;

@protocol TPPBookButtonsDelegate

- (void)didSelectReturnForBook:(TPPBook *_Nullable)book completion:(void (^ _Nullable)(void))completion;
- (void)didSelectDownloadForBook:(TPPBook *_Nullable)book;
- (void)didSelectReadForBook:(TPPBook *_Nullable)book completion:(void (^ _Nullable)(void))completion;
- (void)didSelectPlaySample:(TPPBook *_Nullable)book;

@end

@protocol TPPBookButtonsSampleDelegate

- (void)didSelectPlaySample:(TPPBook *_Nullable)book completion:(void (^ _Nullable)(void))completion;

@end

@protocol TPPBookDownloadCancellationDelegate

- (void)didSelectCancelForBookDetailDownloadingView:(TPPBookButtonsView *_Nullable)view;
- (void)didSelectCancelForBookDetailDownloadFailedView:(TPPBookButtonsView *_Nullable)failedView;

@end

/// This view class handles the buttons for managing a book all in one place,
/// because that's always identical and used in book cells and book detail views.
@interface TPPBookButtonsView : UIView

@property (nonatomic, weak) TPPBook * _Nullable book;
@property (nonatomic) TPPBookButtonsState state;
@property (nonatomic, weak) id<TPPBookButtonsDelegate> _Nullable delegate;
@property (nonatomic, weak) id<TPPBookDownloadCancellationDelegate> _Nullable downloadingDelegate;
@property (nonatomic, weak) id<TPPBookButtonsSampleDelegate> _Nullable sampleDelegate;
@property (nonatomic) BOOL showReturnButtonIfApplicable;

- (instancetype _Nullable )initWithSamplesEnabled:(BOOL)samplesEnabled;
- (void)configureForBookDetailsContext;

@end
