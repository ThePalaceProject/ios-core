@class TPPBook;

// No such actual class exists. This merely to provides a little safety around reader-specific
// TOC-related location information. Any object that wants to do something with an opaque location
// must verify that it is of the correct class and then cast it appropriately.
@class TPPReaderRendererOpaqueLocation;
@class TPPReadiumBookmark;

typedef NS_ENUM(NSInteger, NYPLReaderRendererGesture) {
  NYPLReaderRendererGestureToggleUserInterface
};

@protocol TPPReaderRenderer

@property (nonatomic, readonly) BOOL bookIsCorrupt;
@property (nonatomic, readonly) BOOL loaded;
@property (nonatomic, readonly, nonnull) NSArray *TOCElements;
@property (nonatomic, readonly, nonnull) NSArray<TPPReadiumBookmark *> *bookmarkElements;

// This must be called with a reader-appropriate underlying value. Readers implementing this should
// throw |NSInvalidArgumentException| in the event it is not.
- (void)openOpaqueLocation:(nonnull TPPReaderRendererOpaqueLocation *)opaqueLocation;

- (void)gotoBookmark:(nonnull TPPReadiumBookmark *)bookmark;

@end

@protocol TPPReaderRendererDelegate

- (void)renderer:(nonnull id<TPPReaderRenderer>)renderer
didEncounterCorruptionForBook:(nonnull TPPBook *)book;

- (void)rendererDidFinishLoading:(nonnull id<TPPReaderRenderer>)renderer;

- (void)renderer:(nonnull id<TPPReaderRenderer>)renderer
didUpdateProgressWithinBook:(float)progressWithinBook
       pageIndex:(NSUInteger)pageIndex
       pageCount:(NSUInteger)pageCount
  spineItemTitle:(nullable NSString *)spineItemTitle;

- (void)rendererDidBeginLongLoad:(nonnull id<TPPReaderRenderer>)render;

- (void)renderDidEndLongLoad:(nonnull id<TPPReaderRenderer>)render;

- (void)updateBookmarkIcon:(BOOL)on;
- (void)updateCurrentBookmark:(nullable TPPReadiumBookmark*)bookmark;

- (void)renderer:(nonnull id<TPPReaderRenderer>)render didReceiveGesture:(NYPLReaderRendererGesture)gesture;

@end
