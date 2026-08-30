#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Objective-C exception domain used by ``MumbleRunCatchingException``.
extern NSErrorDomain const MumbleObjCExceptionDomain;

/// Runs `block`, turning an Objective-C exception into an `NSError`.
///
/// Swift has no `@catch`. An `NSException` raised inside a call made from Swift is not a
/// Swift error and `try` does not see it: it unwinds through the Swift frames and, in an
/// async function, takes the whole task with it — no `catch` runs, no `defer` runs, and any
/// state the task was going to set is simply never set.
///
/// AVFAudio raises one for ordinary, recoverable conditions. `installTapOnBus:` does it when
/// the format it is handed no longer matches the bus, which is what a Bluetooth headset
/// changing profile mid-call looks like from here. Routing those calls through this turns an
/// unrecoverable unwind into an error that can be handled like any other.
///
/// - Returns: `YES` if the block completed, `NO` if it raised.
BOOL MumbleRunCatchingException(void (NS_NOESCAPE ^block)(void),
                                NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
