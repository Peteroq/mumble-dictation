#import "MumbleObjC.h"

NSErrorDomain const MumbleObjCExceptionDomain = @"ai.pivotstudio.mumble.ObjCException";

BOOL MumbleRunCatchingException(void (NS_NOESCAPE ^block)(void),
                                NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:MumbleObjCExceptionDomain
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: reason,
                @"exceptionName": exception.name,
            }];
        }
        return NO;
    }
}
