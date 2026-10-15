#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs the block and hands back the Objective-C exception it raised, instead of letting it end the app.
/// Swift cannot catch these; Foundation raises them for misuse such as an undo stack in an invalid state.
NSException * _Nullable FaciendaCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
