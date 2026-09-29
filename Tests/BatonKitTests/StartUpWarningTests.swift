import Foundation
import Testing

@Suite("Start-up warnings")
struct StartUpWarningTests {
    /// Swift runs no didSet for what a class sets in its own init. A warning found at start (a folder on a disk that is
    /// not connected, Baton run from Downloads, an untested Claude) that went through one would reach the footer only
    /// after the first open, so the app's model sets no property with an observer in its init.
    @Test func theAppsInitSetsNoPropertyWithAnObserver() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repo.appending(path: "Sources/BatonApp/AppModel.swift"), encoding: .utf8)
        func matches(_ pattern: String, in text: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: pattern)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range(at: match.numberOfRanges - 1), in: text).map { String(text[$0]) }
            }
        }
        let observed = try matches(#"var (\w+)[^\n{]*\{ *(?:didSet|willSet)"#, in: source)
        #expect(observed.contains("openWarning") && observed.contains("errorMessage"), "the pattern still finds them")

        let start = try #require(source.range(of: "\n    init() {\n"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let initBody = String(source[start.upperBound..<end.lowerBound])
        #expect(initBody.contains("warnAtStartUp("), "the start-up warnings are still set in init")
        for name in observed {
            #expect(try matches(#"(?<![\w.])(?:self\.)?("# + name + #")\s*=(?!=)"#, in: initBody).isEmpty, "init sets \(name)")
        }
    }
}
