//
//  ObjCExceptionCatcher.h
//  PalaceTests
//
//  Utility to catch Objective-C exceptions in Swift tests.
//  Swift's do-catch cannot catch NSException, but we need to test
//  that certain inputs would crash without our defensive measures.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Executes a block and catches any Objective-C exception.
/// @param block The block to execute
/// @return The caught NSException, or nil if no exception was thrown
+ (nullable NSException *)catchExceptionInBlock:(void (^)(void))block;

/// Executes a block and returns YES if an exception was thrown.
/// @param block The block to execute
/// @return YES if an exception was thrown, NO otherwise
+ (BOOL)throwsExceptionInBlock:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
