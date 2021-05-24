// This class is intended for internal use by TPPBookRegistry.

@class TPPBook;
@class TPPBookLocation;
@class TPPReadiumBookmark;
typedef NS_ENUM(NSInteger, TPPBookState);

@interface TPPBookRegistryRecord : NSObject

@property (nonatomic, readonly) TPPBook *book;
@property (nonatomic, readonly) TPPBookLocation *location; // nilable
@property (nonatomic, readonly) TPPBookState state;
@property (nonatomic, readonly) NSString *fulfillmentId; // nilable
@property (nonatomic, readonly) NSArray<TPPReadiumBookmark *> *readiumBookmarks; // nilable
@property (nonatomic, readonly) NSArray<TPPBookLocation *> *genericBookmarks; // nilable

+ (id)new NS_UNAVAILABLE;
- (id)init NS_UNAVAILABLE;

// designated initializer
- (instancetype)initWithBook:(TPPBook *)book
                    location:(TPPBookLocation *)location
                       state:(TPPBookState)state
               fulfillmentId:(NSString *)fulfillmentId
            readiumBookmarks:(NSArray<TPPReadiumBookmark *> *)readiumBookmarks
            genericBookmarks:(NSArray<TPPBookLocation *> *)genericBookmarks;

// designated initializer
- (instancetype)initWithDictionary:(NSDictionary *)dictionary;

- (NSDictionary *)dictionaryRepresentation;

- (instancetype)recordWithBook:(TPPBook *)book;

- (instancetype)recordWithLocation:(TPPBookLocation *)location;

- (instancetype)recordWithState:(TPPBookState)state;

- (instancetype)recordWithFulfillmentId:(NSString *)fulfillmentId;

- (instancetype)recordWithReadiumBookmarks:(NSArray<TPPReadiumBookmark *> *)bookmarks;

- (instancetype)recordWithGenericBookmarks:(NSArray<TPPBookLocation *> *)bookmarks;

@end
