#import "TPPBookButtonsState.h"

@class TPPBook;
@class TPPBookButtonsView;
@class TPPBookDetailDownloadFailedView;

@protocol TPPBookButtonsDelegate

- (void)didSelectReturnForBook:(TPPBook *)book;
- (void)didSelectDownloadForBook:(TPPBook *)book;
- (void)didSelectReadForBook:(TPPBook *)book;

@end

@protocol TPPBookDownloadCancellationDelegate

- (void)didSelectCancelForBookDetailDownloadingView:(TPPBookButtonsView *)view;
- (void)didSelectCancelForBookDetailDownloadFailedView:(TPPBookButtonsView *)failedView;

@end

/// This view class handles the buttons for managing a book all in one place,
/// because that's always identical and used in book cells and book detail views.
@interface TPPBookButtonsView : UIView

@property (nonatomic, weak) TPPBook *book;
@property (nonatomic) TPPBookButtonsState state;
@property (nonatomic, weak) id<TPPBookButtonsDelegate> delegate;
@property (nonatomic, weak) id<TPPBookDownloadCancellationDelegate> downloadingDelegate;
@property (nonatomic) BOOL showReturnButtonIfApplicable;

- (void)configureForBookDetailsContext;

@end
