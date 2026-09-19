#import "ObjCExceptionGuard.h"

NSException * _Nullable __tryCatch(void (^ _Nonnull block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
