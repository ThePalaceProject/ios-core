// This class is intended for internal use by TPPBookRegistry only.

@class TPPBook;

@interface TPPBookCoverRegistry : NSObject

// All handlers are called on the main thread.

- (void)thumbnailImageForBook:(TPPBook *)book
                      handler:(void (^)(UIImage *image))handler;

- (void)coverImageForBook:(TPPBook *)book
                  handler:(void (^)(UIImage *image))handler;

// The set passed in must contain TPPBook objects. The dictionary passed to the handler maps book
// identifiers to images.
- (void)thumbnailImagesForBooks:(NSSet *)books
                        handler:(void (^)(NSDictionary *bookIdentifiersToImages))handler;

// Immediately returns the cached thumbnail if available, else nil. Generated images are not
// returned.
- (UIImage *)cachedThumbnailImageForBook:(TPPBook *)book;

// Pinned images will remain on-disk until they are manually unpinned. Only pinned images are
// guaranteed to be available when offline.
- (void)pinThumbnailImageForBook:(TPPBook *)book;

- (void)removePinnedThumbnailImageForBookIdentifier:(NSString *)bookIdentifier;

- (void)removeAllPinnedThumbnailImages;

@end
