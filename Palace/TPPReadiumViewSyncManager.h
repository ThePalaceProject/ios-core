#import <Foundation/Foundation.h>

@class Account;
@class TPPBook;
@class TPPBookLocation;
@class TPPReadiumBookmark;

typedef NS_ENUM(NSInteger, NYPLReadPositionSyncStatus) {
  NYPLReadPositionSyncStatusIdle,
  NYPLReadPositionSyncStatusBusy
};

@protocol NYPLReadiumViewSyncManagerDelegate <NSObject>

@required
- (void)patronDecidedNavigation:(BOOL)toLatestPage
                    withNavDict:(NSDictionary *)dict;

- (void)uploadFinishedForBookmark:(TPPReadiumBookmark *)bookmark
                           inBook:(NSString *)bookID;
@end

@interface TPPReadiumViewSyncManager : NSObject

- (instancetype)initWithBookID:(NSString *)bookID
                annotationsURL:(NSURL *)URL
                       bookMap:(NSDictionary *)map
                      delegate:(id)delegate;

- (void)syncAllAnnotationsWithPackage:(NSDictionary *)packageDict;
- (void)postLastReadPosition:(NSString *)location;

- (void)syncBookmarksWithCompletion:(void(^)(BOOL success, NSArray<TPPReadiumBookmark *> *bookmarks))completion;

- (void)addBookmark:(TPPReadiumBookmark *)bookmark
            withCFI:(NSString *)location
            forBook:(NSString *)bookID;

@end
