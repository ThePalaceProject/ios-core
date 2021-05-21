#import "TPPReaderRenderer.h"

@class TPPBook;
@class TPPReadiumViewSyncManager;

@interface TPPReaderReadiumView : UIView <TPPReaderRenderer>

@property (nonatomic, weak) id<TPPReaderRendererDelegate> delegate;
@property (nonatomic) TPPReadiumViewSyncManager *syncManager;
@property (nonatomic, readonly) BOOL isPageTurning;
@property (nonatomic, readonly) BOOL canGoRight, canGoLeft;

- (id)init NS_UNAVAILABLE;
- (id)initWithCoder:(NSCoder *)aDecoder NS_UNAVAILABLE;
- (id)initWithFrame:(CGRect)frame NS_UNAVAILABLE;

- (instancetype)initWithFrame:(CGRect)frame
                         book:(TPPBook *)book
                     delegate:(id<TPPReaderRendererDelegate>)delegate;

- (void) applyMediaOverlayPlaybackToggle;
- (void) openPageLeft;
- (void) openPageRight;

- (NSString*) currentChapter;

- (void) addBookmark;
- (void) deleteBookmark:(TPPReadiumBookmark*)bookmark;

@end
