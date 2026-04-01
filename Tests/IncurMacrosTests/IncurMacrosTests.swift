import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(IncurMacros)
import IncurMacros

let testMacros: [String: Macro.Type] = [
    "IncurArgs": IncurArgsMacro.self,
    "IncurOptions": IncurOptionsMacro.self,
    "IncurEnv": IncurEnvMacro.self,
    "Incur": IncurFieldMacro.self,
]
#endif

final class IncurMacrosTests: XCTestCase {

    // MARK: - IncurArgs Tests

    func testIncurArgsBasic() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurArgs
            struct GetArgs {
                var id: String
                var count: Int
            }
            """,
            expandedSource: """
            struct GetArgs {
                var id: String
                var count: Int

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "id",
                            cliName: "id",
                            description: nil,
                            fieldType: .string,
                            required: true,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        ),
                        FieldMeta(
                            name: "count",
                            cliName: "count",
                            description: nil,
                            fieldType: .number,
                            required: true,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    guard let id = raw["id"]?.stringValue else {
                        throw ValidationError(message: "Missing required argument: id")
                    }
                    guard let _count_raw = raw["count"]?.intValue else {
                        throw ValidationError(message: "Missing required argument: count")
                    }
                    let count = Int(_count_raw)
                    return Self(id: id, count: count)
                }
            }

            extension GetArgs: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurArgsOptional() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurArgs
            struct SearchArgs {
                var query: String
                var format: String?
            }
            """,
            expandedSource: """
            struct SearchArgs {
                var query: String
                var format: String?

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "query",
                            cliName: "query",
                            description: nil,
                            fieldType: .string,
                            required: true,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        ),
                        FieldMeta(
                            name: "format",
                            cliName: "format",
                            description: nil,
                            fieldType: .string,
                            required: false,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    guard let query = raw["query"]?.stringValue else {
                        throw ValidationError(message: "Missing required argument: query")
                    }
                    let format = raw["format"]?.stringValue
                    return Self(query: query, format: format)
                }
            }

            extension SearchArgs: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurArgsDocComment() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurArgs
            struct GetArgs {
                /// The user ID to fetch
                var id: String
            }
            """,
            expandedSource: """
            struct GetArgs {
                /// The user ID to fetch
                var id: String

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "id",
                            cliName: "id",
                            description: "The user ID to fetch",
                            fieldType: .string,
                            required: true,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    guard let id = raw["id"]?.stringValue else {
                        throw ValidationError(message: "Missing required argument: id")
                    }
                    return Self(id: id)
                }
            }

            extension GetArgs: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    // MARK: - IncurOptions Tests

    func testIncurOptionsAlias() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurOptions
            struct ListOptions {
                @Incur(alias: "n")
                var limit: Int
            }
            """,
            expandedSource: """
            struct ListOptions {
                var limit: Int

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "limit",
                            cliName: "limit",
                            description: nil,
                            fieldType: .number,
                            required: true,
                            defaultValue: nil,
                            alias: Character("n"),
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    guard let _limit_raw = raw["limit"]?.intValue else {
                        throw ValidationError(message: "Missing required option: limit")
                    }
                    let limit = Int(_limit_raw)
                    return Self(limit: limit)
                }
            }

            extension ListOptions: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurOptionsDefault() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurOptions
            struct ListOptions {
                @Incur(default: 10)
                var limit: Int
            }
            """,
            expandedSource: """
            struct ListOptions {
                var limit: Int

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "limit",
                            cliName: "limit",
                            description: nil,
                            fieldType: .number,
                            required: false,
                            defaultValue: .int(10),
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    let limit = Int(raw["limit"]?.intValue ?? 10)
                    return Self(limit: limit)
                }
            }

            extension ListOptions: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurOptionsCount() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurOptions
            struct VerboseOptions {
                @Incur(count: true)
                var verbose: Int
            }
            """,
            expandedSource: """
            struct VerboseOptions {
                var verbose: Int

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "verbose",
                            cliName: "verbose",
                            description: nil,
                            fieldType: .count,
                            required: false,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    let verbose = raw["verbose"]?.intValue ?? 0
                    return Self(verbose: verbose)
                }
            }

            extension VerboseOptions: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurOptionsDeprecated() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurOptions
            struct OldOptions {
                @Incur(deprecated: true)
                var legacyMode: Bool
            }
            """,
            expandedSource: """
            struct OldOptions {
                var legacyMode: Bool

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "legacyMode",
                            cliName: "legacy-mode",
                            description: nil,
                            fieldType: .boolean,
                            required: false,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: true,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    let legacyMode = raw["legacyMode"]?.boolValue ?? false
                    return Self(legacyMode: legacyMode)
                }
            }

            extension OldOptions: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurOptionsBoolNotRequired() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurOptions
            struct FlagOptions {
                var verbose: Bool
            }
            """,
            expandedSource: """
            struct FlagOptions {
                var verbose: Bool

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "verbose",
                            cliName: "verbose",
                            description: nil,
                            fieldType: .boolean,
                            required: false,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    let verbose = raw["verbose"]?.boolValue ?? false
                    return Self(verbose: verbose)
                }
            }

            extension FlagOptions: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurOptionsArrayNotRequired() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurOptions
            struct TagOptions {
                var tags: [String]
            }
            """,
            expandedSource: """
            struct TagOptions {
                var tags: [String]

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "tags",
                            cliName: "tags",
                            description: nil,
                            fieldType: .array(.string),
                            required: false,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: nil
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    let tags = raw["tags"]?.arrayValue?.compactMap {
                        $0.stringValue
                    } ?? []
                    return Self(tags: tags)
                }
            }

            extension TagOptions: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    // MARK: - IncurEnv Tests

    func testIncurEnvBasic() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurEnv
            struct AppEnv {
                @Incur(env: "API_TOKEN")
                var apiToken: String
            }
            """,
            expandedSource: """
            struct AppEnv {
                var apiToken: String

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "apiToken",
                            cliName: "api-token",
                            description: nil,
                            fieldType: .string,
                            required: true,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: "API_TOKEN"
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    guard let apiToken = raw["apiToken"]?.stringValue else {
                        throw ValidationError(message: "Missing required env var: apiToken")
                    }
                    return Self(apiToken: apiToken)
                }
            }

            extension AppEnv: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurEnvFallbackName() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurEnv
            struct AppEnv {
                var apiToken: String
            }
            """,
            expandedSource: """
            struct AppEnv {
                var apiToken: String

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "apiToken",
                            cliName: "api-token",
                            description: nil,
                            fieldType: .string,
                            required: true,
                            defaultValue: nil,
                            alias: nil,
                            deprecated: false,
                            envName: "API_TOKEN"
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    guard let apiToken = raw["apiToken"]?.stringValue else {
                        throw ValidationError(message: "Missing required env var: apiToken")
                    }
                    return Self(apiToken: apiToken)
                }
            }

            extension AppEnv: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIncurEnvDefault() throws {
        #if canImport(IncurMacros)
        assertMacroExpansion(
            """
            @IncurEnv
            struct AppEnv {
                @Incur(env: "BASE_URL", default: "https://api.example.com")
                var baseUrl: String
            }
            """,
            expandedSource: """
            struct AppEnv {
                var baseUrl: String

                static func fields() -> [FieldMeta] {
                    [
                        FieldMeta(
                            name: "baseUrl",
                            cliName: "base-url",
                            description: nil,
                            fieldType: .string,
                            required: false,
                            defaultValue: .string("https://api.example.com"),
                            alias: nil,
                            deprecated: false,
                            envName: "BASE_URL"
                        )
                    ]
                }

                static func fromRaw(_ raw: OrderedMap) throws -> Self {
                    let baseUrl = raw["baseUrl"]?.stringValue ?? "https://api.example.com"
                    return Self(baseUrl: baseUrl)
                }
            }

            extension AppEnv: IncurSchema {
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }
}
