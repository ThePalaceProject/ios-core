#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C @try/@catch into Swift.
/// Swift's do/catch cannot catch NSException (e.g. NSInternalInconsistencyException
/// from WebKit's HTML parser). This utility lets production code recover gracefully
/// instead of crashing.
@interface TPPObjCExceptionCatcher : NSObject

/// Executes @p block inside @try and returns the caught NSException, or nil.
+ (nullable NSException *)catchExceptionInBlock:(void (NS_NOESCAPE ^)(void))block;

/// Like @c catchExceptionInBlock: but also catches escaping C++ exceptions
/// (e.g. @c Botan::Decoding_Error from R2LCPClient) and wraps them in a
/// synthetic @c NSException whose @c reason carries @c std::exception::what().
/// Use at FFI seams where C++ exceptions can otherwise propagate to
/// @c std::terminate and crash the app.
+ (nullable NSException *)catchAllExceptionsInBlock:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
