import Foundation
import MumbleObjC
import Testing

/// The one thing this target exists for: an Objective-C exception raised inside a call made
/// from Swift has to come back as a value, not as an unwind. If this ever stops holding, a
/// microphone changing mid-recording takes the whole recording task with it and the app sits
/// with its HUD up until it is quit.
struct ExceptionCatchTests {
    @Test func aRaisedExceptionBecomesAnError() {
        var error: NSError?
        let completed = MumbleRunCatchingException({
            NSException(name: .invalidArgumentException, reason: "format mismatch", userInfo: nil).raise()
        }, &error)

        #expect(completed == false)
        #expect(error?.localizedDescription == "format mismatch")
        #expect(error?.userInfo["exceptionName"] as? String == NSExceptionName.invalidArgumentException.rawValue)
    }

    @Test func codeAfterTheCallStillRuns() {
        var reached = false
        var error: NSError?
        _ = MumbleRunCatchingException({
            NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
        }, &error)
        // The point of the whole exercise. Without the @try this line is never reached.
        reached = true
        #expect(reached)
    }

    @Test func anOrdinaryBlockReportsSuccessAndRunsItsEffects() {
        var ran = false
        var error: NSError?
        let completed = MumbleRunCatchingException({ ran = true }, &error)

        #expect(completed)
        #expect(ran)
        #expect(error == nil)
    }

    @Test func aNilErrorPointerIsSafe() {
        let completed = MumbleRunCatchingException({
            NSException(name: .rangeException, reason: "out of range", userInfo: nil).raise()
        }, nil)
        #expect(completed == false)
    }
}
