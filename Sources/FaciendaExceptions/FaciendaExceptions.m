#import "FaciendaExceptions.h"

NSException * _Nullable FaciendaCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
