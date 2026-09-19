#import <Foundation/Foundation.h>

/// macOS 27 workaround: run a block inside ObjC @try/@catch.
/// Returns the caught exception, or nil if no exception was thrown.
NSException * _Nullable __tryCatch(void (^ _Nonnull block)(void));
