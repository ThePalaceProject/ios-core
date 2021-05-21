@class TPPReaderRendererOpaqueLocation;
@class TPPReaderTOCViewController;
@class TPPReadiumBookmark;

@protocol TPPReaderTOCViewControllerDelegate

- (void)TOCViewController:(TPPReaderTOCViewController *)controller
  didSelectOpaqueLocation:(TPPReaderRendererOpaqueLocation *)opaqueLocation;

- (void)TOCViewController:(TPPReaderTOCViewController *)controller
        didSelectBookmark:(TPPReadiumBookmark *)bookmark;

- (void)TOCViewController:(TPPReaderTOCViewController *)controller
        didDeleteBookmark:(TPPReadiumBookmark *)bookmark;

- (void)TOCViewController:(TPPReaderTOCViewController *)controller
didRequestSyncBookmarksWithCompletion:
  (void(^)(BOOL success, NSArray<TPPReadiumBookmark *> *bookmarks))completion;

@end

/// VC handling TOC and Bookmarks for Readium 1 reader.
@interface TPPReaderTOCViewController : UIViewController

@property (nonatomic, weak) id<TPPReaderTOCViewControllerDelegate> delegate;
@property (nonatomic) NSArray *tableOfContents;
@property (nonatomic) NSMutableArray<TPPReadiumBookmark *> *bookmarks;
@property (nonatomic) NSString *bookTitle;
@property (nonatomic) NSString *currentChapter;


@end
