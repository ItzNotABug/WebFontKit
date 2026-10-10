import Foundation
import os
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct RegistrationBridgeTests {
    @Test("the handler may run several times; the bridge collects every failure and resumes once, when done")
    func severalCalls() async {
        let a = URL(fileURLWithPath: "/tmp/a.wfkfont")
        let b = URL(fileURLWithPath: "/tmp/b.wfkfont")
        let c = URL(fileURLWithPath: "/tmp/c.wfkfont")
        let result = await CoreTextRegistrar.bridge([a, b, c]) { _, handler in
            handler([.init(code: 305, urls: [a])], false)
            handler([.init(code: 105, urls: [b])], false)
            handler([], true)
            handler([.init(code: 999, urls: [c])], true)
        }
        #expect(result == [a: 305, b: 105])
    }

    @Test("a handler that reports done from another thread resumes the waiter")
    func asynchronousDone() async {
        let a = URL(fileURLWithPath: "/tmp/a.wfkfont")
        let result = await CoreTextRegistrar.bridge([a]) { _, handler in
            DispatchQueue.global().async {
                handler([.init(code: 104, urls: [a])], true)
            }
        }
        #expect(result == [a: 104])
    }

    @Test("failures are keyed by the caller's URL, whatever spelling CoreText reports")
    func spelling() async throws {
        let directory = TempDirectory()
        let mine = directory.url.appending(component: "a.wfkfont")
        try Data().write(to: mine)
        let reported = mine.resolvingSymlinksInPath()
        let result = await CoreTextRegistrar.bridge([mine]) { _, handler in
            handler([.init(code: 305, urls: [reported])], true)
        }
        #expect(result == [mine: 305])
    }

    @Test("an empty batch makes no CoreText call")
    func empty() async {
        let called = OSAllocatedUnfairLock(initialState: false)
        let result = await CoreTextRegistrar.bridge([]) { _, handler in
            called.withLock { $0 = true }
            handler([], true)
        }
        #expect(result.isEmpty)
        #expect(!called.withLock { $0 })
    }
}
