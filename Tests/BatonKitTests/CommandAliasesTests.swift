import Testing

@testable import BatonKit

@Suite("Command aliases")
struct CommandAliasesTests {
    @Test func passIsContinue() {
        #expect(CommandAliases.resolve(["pass", "last", "--to", "LAB"]) == ["continue", "last", "--to", "LAB"])
        #expect(
            CommandAliases.resolve(["pass", "--folder", "~/Projects/api", "--to", "LAB", "--dry-run"])
                == ["continue", "--folder", "~/Projects/api", "--to", "LAB", "--dry-run"])
    }

    @Test func onlyTheCommandPositionIsAnAlias() {
        #expect(CommandAliases.resolve(["continue", "pass", "--to", "LAB"]) == ["continue", "pass", "--to", "LAB"])
        #expect(CommandAliases.resolve(["rules"]) == ["rules"])
        #expect(CommandAliases.resolve([]) == [])
    }
}
