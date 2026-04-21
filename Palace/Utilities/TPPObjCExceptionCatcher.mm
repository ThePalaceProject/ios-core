#import "TPPObjCExceptionCatcher.h"
#include <exception>
#include <string>

@implementation TPPObjCExceptionCatcher

+ (nullable NSException *)catchExceptionInBlock:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
    }
    @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

+ (nullable NSException *)catchAllExceptionsInBlock:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
    }
    @catch (NSException *exception) {
        return exception;
    }
    @catch (...) {
        // Catch C++ exceptions (e.g. Botan::Decoding_Error, std::system_error)
        NSString *reason = @"Unknown C++ exception";
        try {
            std::rethrow_exception(std::current_exception());
        } catch (const std::exception &e) {
            reason = [NSString stringWithUTF8String:e.what()];
        } catch (...) {
            // truly unknown — keep default reason
        }
        return [NSException exceptionWithName:@"CppException"
                                       reason:reason
                                     userInfo:nil];
    }
    return nil;
}

@end
