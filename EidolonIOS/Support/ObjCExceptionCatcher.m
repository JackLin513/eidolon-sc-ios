#import "ObjCExceptionCatcher.h"

NSString *EIDCatchObjectiveCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}
