/// Macro declarations for the incur framework.
///
/// These macros generate `IncurSchema` conformances from struct declarations,
/// mirroring the Rust derive macros in `incur-macros`.

/// Generates `IncurSchema` conformance for a positional-argument struct.
///
/// Fields are treated as positional args in declaration order. `Optional<T>` fields
/// are optional; all others are required.
///
/// Example:
/// ```swift
/// @IncurArgs
/// struct GetArgs {
///     /// The user ID to fetch
///     var id: Int
///     /// Optional format override
///     var format: String?
/// }
/// ```
@attached(member, names: named(fields), named(fromRaw))
@attached(extension, conformances: IncurSchema)
public macro IncurArgs() = #externalMacro(module: "IncurMacros", type: "IncurArgsMacro")

/// Generates `IncurSchema` conformance for a named-options struct.
///
/// Supports `@Incur(alias:)`, `@Incur(default:)`, `@Incur(count:)`, and
/// `@Incur(deprecated:)` attributes on fields.
///
/// - `Bool` fields are never required.
/// - `[T]` (Array) fields are never required.
/// - Fields with defaults are never required.
///
/// Example:
/// ```swift
/// @IncurOptions
/// struct ListOptions {
///     /// Maximum number of results
///     @Incur(alias: "n", default: 10)
///     var limit: Int
///     /// Include archived items
///     @Incur(alias: "a")
///     var archived: Bool
/// }
/// ```
@attached(member, names: named(fields), named(fromRaw))
@attached(extension, conformances: IncurSchema)
public macro IncurOptions() = #externalMacro(module: "IncurMacros", type: "IncurOptionsMacro")

/// Generates `IncurSchema` conformance for an environment-variable binding struct.
///
/// Supports `@Incur(env:)` for explicit env var names and `@Incur(default:)` for defaults.
/// Falls back to SCREAMING_SNAKE_CASE of the field name when no `env:` is provided.
///
/// Example:
/// ```swift
/// @IncurEnv
/// struct AppEnv {
///     /// API token for authentication
///     @Incur(env: "API_TOKEN")
///     var apiToken: String
///     /// Base URL
///     @Incur(env: "BASE_URL", default: "https://api.example.com")
///     var baseUrl: String
/// }
/// ```
@attached(member, names: named(fields), named(fromRaw))
@attached(extension, conformances: IncurSchema)
public macro IncurEnv() = #externalMacro(module: "IncurMacros", type: "IncurEnvMacro")

/// Attribute macro for annotating individual fields within `@IncurOptions` or `@IncurEnv` structs.
///
/// This is a marker macro — the actual parsing of its arguments is done by the
/// enclosing struct-level macro (`IncurOptions`, `IncurEnv`).
///
/// Supported arguments:
/// - `alias: "x"` — single-char short alias (e.g. `-n`)
/// - `default: <value>` — default value (string, int, float, or bool literal)
/// - `count: true` — marks a field as a count flag (`-vvv` -> 3)
/// - `deprecated: true` — marks the option as deprecated
/// - `env: "VAR_NAME"` — environment variable name
@attached(peer)
public macro IncurField(
    alias: String? = nil,
    default defaultValue: Any? = nil,
    count: Bool = false,
    deprecated: Bool = false,
    env: String? = nil
) = #externalMacro(module: "IncurMacros", type: "IncurFieldMacro")
