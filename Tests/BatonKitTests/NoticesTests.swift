import Foundation
import Testing

@testable import BatonKit

@Suite("Window notices")
struct NoticesTests {
    private let warning = "Claude (main) will continue it by itself when its limit resets. Turn off Auto-continue there."
    private let roomAgain = "Claude LAB has room again."

    /// Another window gets room again while a Continue warning is unread: its notice shows for a while, then the
    /// warning is back. Before, the notice replaced the warning and then cleared itself, and the warning was gone.
    @Test func aPassingNoticeDoesNotLoseAWarning() {
        var notices = Notices()
        notices.show(warning, isWarning: true)
        notices.show(roomAgain, isWarning: false)
        #expect(notices.current?.text == roomAgain)
        #expect(notices.current?.isWarning == false)
        notices.expire(roomAgain)
        #expect(notices.current?.text == warning)
        #expect(notices.current?.isWarning == true)
    }

    /// Closing the notice on top shows the warning under it; closing the warning ends it.
    @Test func dismissingShowsTheWarningUnderneath() {
        var notices = Notices()
        notices.show(warning, isWarning: true)
        notices.show(roomAgain, isWarning: false)
        notices.dismiss()
        #expect(notices.current?.text == warning)
        notices.dismiss()
        #expect(notices.current == nil)
    }

    /// Warnings wait for their own dismissal, newest first, each once; an earlier notice's timer leaves a newer one.
    @Test func warningsStayUntilEachIsDismissed() {
        var notices = Notices()
        notices.show("First warning.", isWarning: true)
        notices.show(warning, isWarning: true)
        notices.show("First warning.", isWarning: true)
        #expect(notices.current?.text == "First warning.")
        notices.expire("First warning.")
        #expect(notices.current?.text == "First warning.")
        notices.dismiss()
        #expect(notices.current?.text == warning)
        notices.dismiss()
        #expect(notices.current == nil)

        notices.show("Opened.", isWarning: false)
        notices.show(roomAgain, isWarning: false)
        notices.expire("Opened.")
        #expect(notices.current?.text == roomAgain)
        notices.expire(roomAgain)
        #expect(notices.current == nil)
    }
}
