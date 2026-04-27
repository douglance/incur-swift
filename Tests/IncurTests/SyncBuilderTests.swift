import Foundation
import Testing
@testable import Incur

@Suite("CliSyncBuilder")
struct CliSyncBuilderTests {

    @Test func defaultSyncOptionsAreNil() {
        let cli = Cli("foo")
        #expect(cli.syncOptions == nil)
    }

    @Test func syncBuilderStoresOptions() {
        let cwd = URL(fileURLWithPath: "/tmp/foo")
        let cli = Cli("foo")
            .sync(
                cwd: cwd,
                depth: 2,
                include: ["docs/**", "skills/*"],
                suggestions: ["foo bar", "foo baz"]
            )

        let opts = cli.syncOptions
        #expect(opts != nil)
        #expect(opts?.depth == 2)
        #expect(opts?.cwd == cwd)
        #expect(opts?.include == ["docs/**", "skills/*"])
        #expect(opts?.suggestions == ["foo bar", "foo baz"])
    }

    @Test func syncBuilderAcceptsExplicitStruct() {
        let opts = CliSyncOptions(depth: 5, include: ["a"], suggestions: ["x"])
        let cli = Cli("foo").sync(opts)
        #expect(cli.syncOptions?.depth == 5)
        #expect(cli.syncOptions?.include == ["a"])
        #expect(cli.syncOptions?.suggestions == ["x"])
    }

    @Test func syncBuilderPartialFields() {
        let cli = Cli("foo").sync(depth: 3)
        #expect(cli.syncOptions?.depth == 3)
        #expect(cli.syncOptions?.cwd == nil)
        #expect(cli.syncOptions?.include == nil)
        #expect(cli.syncOptions?.suggestions == nil)
    }

    @Test func syncBuilderIsChainable() {
        let cli = Cli("foo")
            .description("desc")
            .version("1.0.0")
            .sync(depth: 4, suggestions: ["foo a"])

        #expect(cli.cliDescription == "desc")
        #expect(cli.version == "1.0.0")
        #expect(cli.syncOptions?.depth == 4)
        #expect(cli.syncOptions?.suggestions == ["foo a"])
    }
}
