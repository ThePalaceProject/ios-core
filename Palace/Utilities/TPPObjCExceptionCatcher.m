#import "TPPObjCExceptionCatcher.h"

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

@end
