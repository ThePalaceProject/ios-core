// This class encapsulates all access to book metadata and covers. All methods are thread-safe.

@class TPPBook;
@class TPPBookLocation;
@class TPPReadiumBookmark;

typedef NS_ENUM(NSInteger, TPPBookState);

@protocol TPPBookRegistryProvider <NSObject>

- (nonnull NSArray<TPPReadiumBookmark *> *)readiumBookmarksForIdentifier:(nonnull NSString *)identifier;

- (void)setLocation:(nullable TPPBookLocation *)location
      forIdentifier:(nonnull NSString *)identifier;

- (nullable TPPBookLocation *)locationForIdentifier:(nonnull NSString *)identifier;

- (void)addReadiumBookmark:(nonnull TPPReadiumBookmark *)bookmark
             forIdentifier:(nonnull NSString *)identifier;
  
- (void)deleteReadiumBookmark:(nonnull TPPReadiumBookmark *)bookmark
                forIdentifier:(nonnull NSString *)identifier;

- (void)replaceBookmark:(nonnull TPPReadiumBookmark *)oldBookmark
                   with:(nonnull TPPReadiumBookmark *)newBookmark
          forIdentifier:(nonnull NSString *)identifier;

@end

@interface TPPBookRegistry : NSObject <TPPBookRegistryProvider>

// Returns all registered books.
@property (atomic, readonly, nonnull) NSArray *allBooks;

// Returns all books that are on hold
@property (atomic, readonly, nonnull) NSArray *heldBooks;

// Returns all books not on hold (borrowed or kept)
@property (atomic, readonly, nonnull) NSArray *myBooks;

// Returns the number of books currently registered.
@property (atomic, readonly) NSUInteger count;

// Returns YES if the registry is currently syncing, else NO;
@property (atomic, readonly) BOOL syncing;

+ (nonnull id)new NS_UNAVAILABLE;
- (nonnull id)init NS_UNAVAILABLE;

+ (nonnull TPPBookRegistry *)sharedRegistry;

// Returns the URL of the directory used by the registry for storing content and metadata. The
// directory is not guaranteed to exist at the time this method is called.
- (nullable NSURL *)registryDirectory;

/**
 Saves the registry to disk. This should be called before the application
 is terminated.
 */
- (void)save;

/**
 Loads the registry from disk.
 */
- (void)justLoad;

/**
 Grandfathering original sync method. Passes nil for the background fetch handler.

 @param shouldResetCache Whether we should wipe the whole cache of
 loans/holds/book details/open search/ungrouped feeds in its entirety or not.
 @param handler Completion Handler is on main thread, but not gauranteed to be called.
 */
- (void)syncResettingCache:(BOOL)shouldResetCache
         completionHandler:(void (^ _Nullable)(NSDictionary * _Nullable errorDict))handler;

/**
 Syncs the latest loans content from the server. Attempting to sync while one is
 already in progress will be ignored. Resetting the registry while a sync is in
 progress will cause the handler not to be called.

 Errors are logged via TPPErrorLogger.

 @param shouldResetCache Whether we should wipe the whole cache of
 loans/holds/book details/open search/ungrouped feeds in its entirety or not.
 @param handler Called on completion on the main thread. Not guaranteed to be
 called.
 @param fetchHandler Called on completion on the main thread while exceuting
 from a Background App State, like from the App Delegate method. Calls to this
 block should be balanced with calls to the method.
 */
- (void)syncResettingCache:(BOOL)shouldResetCache
         completionHandler:(void (^ _Nullable)(NSDictionary * _Nullable errorDict))handler
    backgroundFetchHandler:(void (^ _Nullable)(UIBackgroundFetchResult))fetchHandler;

/**
 Calls syncWithCompletionHandler: with a handler that presents standard
 success/failure alerts on completion.
 */
- (void)syncWithStandardAlertsOnCompletion;

// Adds a book to the book registry until it is manually removed. It allows the application to
// present information about obtained books when offline. Attempting to add a book already present
// will overwrite the existing book as if |updateBook:| were called. The location may be nil. The
// state provided must be one of TPPBookState and must not be |TPPBookStateUnregistered|.
// TODO: Use TPPBookState instead of NSInteger when migrate to Swift
- (void)addBook:(nonnull TPPBook *)book
       location:(nullable TPPBookLocation *)location
          state:(NSInteger)state
  fulfillmentId:(nullable NSString *)fulfillmentId
readiumBookmarks:(nullable NSArray<TPPReadiumBookmark *> *)readiumBookmarks
genericBookmarks:(nullable NSArray<TPPBookLocation *> *)genericBookmarks;

// This method should be called whenever new book information is retrieved from a server. Doing so
// ensures that once the user has seen the new information, they will continue to do so when
// accessing the application off-line or when viewing books outside of the catalog. Attempts to
// update a book not already stored in the registry will simply be ignored, so it's reasonable to
// call this method whenever new information is obtained regardless of a given book's state.
- (void)updateBook:(nonnull TPPBook *)book;

// This will update the book like updateBook does, but will also set its state to unregistered, then
// broadcast the change, then remove the book from the registry. This gives any views using the book
// a chance to update their copy with the new one, without having to keep it in the registry after.
- (void)updateAndRemoveBook:(nonnull TPPBook *)book;

/// Returns the given book after updating its metadata.
/// @note This method should be called whenever new book information is retrieved from a server, but may
///  not include user-specific information. We want to update the metadata, but not overwrite the existing
///  availability information and acquisition URLs.
/// @param book The book we want to update
- (nullable TPPBook *)updatedBookMetadata:(nonnull TPPBook *)book;

// Returns the book for a given identifier if it is registered, else nil.
- (nullable TPPBook *)bookForIdentifier:(nonnull NSString *)identifier;

// Sets the state for a book previously registered given its identifier.
- (void)setState:(TPPBookState)state forIdentifier:(nonnull NSString *)identifier;

// For Swift, since setState method above is not being compiled into the bridging header
// possibly due to the enum TPPBookState is being declared in both Swift and ObjC
// stateCode should always be one of TPPBookState cases
// TODO: Remove when migrate to Swift, use setState:forIdentifier: instead
- (void)setStateWithCode:(NSInteger)stateCode forIdentifier:(nonnull NSString *)identifier;

// Returns the state of a book given its identifier.
- (TPPBookState)stateForIdentifier:(nonnull NSString *)identifier;

// Sets the location for a book previously registered given its identifier.
- (void)setLocation:(nullable TPPBookLocation *)location
      forIdentifier:(nonnull NSString *)identifier;

// Returns the location of a book given its identifier.
- (nullable TPPBookLocation *)locationForIdentifier:(nonnull NSString *)identifier;

// Sets the fulfillmentId for a book previously registered given its identifier.
- (void)setFulfillmentId:(nullable NSString *)fulfillmentId forIdentifier:(nonnull NSString *)identifier;

// Returns whether a book is processing something, given its identifier.
- (BOOL)processingForIdentifier:(nonnull NSString *)identifier;

// Sets the processing flag for a book previously registered given its identifier.
- (void)setProcessing:(BOOL)processing forIdentifier:(nonnull NSString *)identifier;

// Returns the fulfillmentId of a book given its identifier.
- (nullable NSString *)fulfillmentIdForIdentifier:(nonnull NSString *)identifier;
    
// Returns the bookmarks for a book given its identifier
- (nonnull NSArray<TPPReadiumBookmark *> *)readiumBookmarksForIdentifier:(nonnull NSString *)identifier;
  
// Add bookmark for a book given its identifier
- (void)addReadiumBookmark:(nonnull TPPReadiumBookmark *)bookmark
             forIdentifier:(nonnull NSString *)identifier;
  
/**
 Delete bookmark for a book given its identifer and saves updated registry
 to disk.
 */
- (void)deleteReadiumBookmark:(nonnull TPPReadiumBookmark *)bookmark
                forIdentifier:(nonnull NSString *)identifier;

// Replace a bookmark with another, given its identifer
- (void)replaceBookmark:(nonnull TPPReadiumBookmark *)oldBookmark
                   with:(nonnull TPPReadiumBookmark *)newBookmark
          forIdentifier:(nonnull NSString *)identifier;

// Returns the generic bookmarks for a any renderer's bookmarks given its identifier
- (nullable NSArray<TPPBookLocation *> *)genericBookmarksForIdentifier:(nonnull NSString *)identifier;

// Add a generic bookmark (book location) for a book given its identifier
- (void)addGenericBookmark:(nonnull TPPBookLocation *)bookmark
             forIdentifier:(nonnull NSString *)identifier;

// Delete a generic bookmark (book location) for a book given its identifier
- (void)deleteGenericBookmark:(nonnull TPPBookLocation *)bookmark
                forIdentifier:(nonnull NSString *)identifier;

// Given an identifier, this method removes a book from the registry. Attempting to remove a book
// that is not present will result in an error being logged.
- (void)removeBookForIdentifier:(nonnull NSString *)book;

// Returns the thumbnail for a book via a handler called on the main thread. The book does not have
// to be registered in order to retrieve a cover.
- (void)thumbnailImageForBook:(nonnull TPPBook *)book
                      handler:(void (^ _Nonnull)(UIImage * _Nonnull image))handler;

// Returns cover image if it exists, or falls back to thumbnail image load.
- (void)coverImageForBook:(nonnull TPPBook *const)book
                  handler:(void (^ _Nonnull)(UIImage * _Nonnull image))handler;

// The set passed in should contain TPPBook objects. If |books| is nil or does not strictly contain
// TPPBook objects, the handler will be called with nil. Otherwise, the dictionary passed to the
// handler maps book identifiers to images. The handler is always called on the main thread. The
// books do not have to be registered in order to retrieve covers.
- (void)thumbnailImagesForBooks:(nonnull NSSet *)books
                        handler:(void (^ _Nonnull)(NSDictionary * _Nonnull bookIdentifiersToImages))handler;

// Immediately returns the cached thumbnail if available, else nil. Generated images are not
// returned. The book does not have to be registered in order to retrieve a cover.
- (nullable UIImage *)cachedThumbnailImageForBook:(nonnull TPPBook *)book;

// Resets the registry to an empty state.
- (void)reset;

// Resets the registry for a specific account
- (void)reset:(nonnull NSString *)account;

/// Returns all book identifiers in the registry for a given account.
/// @note The identifiers returned should not be passed to @c -[TPPBookRegistry @c bookForIdentifier:]
///       or similar methods unless the account provided to this method is also the currently active account.
/// @param account The id of the account to inspect.
/// @return A possibly empty array of book identifiers.
- (NSArray<NSString *> *_Nonnull)bookIdentifiersForAccount:(nonnull NSString *)account;

// Delay committing any changes from a sync indefinitely.
- (void)delaySyncCommit;

// Stop delaying committing synced data.
- (void)stopDelaySyncCommit;

/// Executes a function that does not modify the registry while the registry is set to a particular account, then
/// restores the registry to the original account afterwards. During the execution of @c block, the registry will
/// temporarily prevent access from other threads.
/// @warning It is an error to modify the registry during the execution of @c block. Doing so will result in undefined
///          behavior.
/// @param account The account to use while @c block is executing.
/// @param block   The function to execute while the registry is set to another account.
- (void)performUsingAccount:(nonnull NSString *)account
                      block:(void (^_Nonnull)(void))block;

@end
