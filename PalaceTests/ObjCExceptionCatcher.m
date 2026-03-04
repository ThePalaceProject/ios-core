//
//  ObjCExceptionCatcher.m
//  PalaceTests
//

#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (nullable NSException *)catchExceptionInBlock:(void (^)(void))block {
    @try {
        block();
    }
    @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

+ (BOOL)throwsExceptionInBlock:(void (^)(void))block {
    return [self catchExceptionInBlock:block] != nil;
}

@end
