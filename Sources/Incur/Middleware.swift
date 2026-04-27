/// Middleware types and composition for the incur framework.
///
/// Middleware wraps command execution in an onion-style chain: each handler
/// receives a context and a `next` function. Calling `next` runs the inner
/// layers (and eventually the command handler). Code before `next()` runs
/// "before" the command; code after runs "after".
///
/// Ported from `middleware.rs`.

import Foundation

/// Context available inside middleware.
public struct MiddlewareContext: Sendable {
    /// Whether the consumer is an agent (stdout is not a TTY).
    public let agent: Bool
    /// The resolved command path (e.g. `"users list"`).
    public let command: String
    /// Parsed environment variables from the CLI-level env schema.
    public let env: JSONValue
    /// The resolved output format.
    public let format: Format
    /// Whether the user explicitly passed `--format` or `--json`.
    public let formatExplicit: Bool
    /// The CLI name.
    public let name: String
    /// Shared variables set by upstream middleware.
    public let vars: MutableVars
    /// The CLI version string.
    public let version: String?

    public init(
        agent: Bool,
        command: String,
        env: JSONValue,
        format: Format,
        formatExplicit: Bool,
        name: String,
        vars: MutableVars,
        version: String?
    ) {
        self.agent = agent
        self.command = command
        self.env = env
        self.format = format
        self.formatExplicit = formatExplicit
        self.name = name
        self.vars = vars
        self.version = version
    }
}

/// Thread-safe mutable variables shared across middleware.
public final class MutableVars: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = OrderedMap()

    public init() {}

    public subscript(key: String) -> JSONValue? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage[key] = newValue
        }
    }

    public func snapshot() -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        return .object(storage)
    }

    /// Returns a snapshot of the underlying ordered map (for validation).
    public func snapshotMap() -> OrderedMap {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// A middleware handler function.
public typealias MiddlewareFn = @Sendable (MiddlewareContext, @escaping @Sendable () async -> Void) async -> Void

/// Composes a slice of middleware into an onion-style chain.
///
/// Middleware is composed right-to-left (the first middleware in the slice
/// is the outermost layer). The `finalHandler` is the innermost function
/// that actually runs the command.
///
/// Given middleware `[A, B]` and a final handler `H`, the execution order is:
/// ```
/// A before → B before → H → B after → A after
/// ```
public func composeMiddleware(
    _ middlewares: [MiddlewareFn],
    ctx: MiddlewareContext,
    finalHandler: @escaping @Sendable () async -> Void
) async {
    // Build the chain from right to left.
    var next: @Sendable () async -> Void = finalHandler

    for mw in middlewares.reversed() {
        let currentNext = next
        let currentMw = mw
        let ctxCopy = ctx
        next = { @Sendable in
            await currentMw(ctxCopy, currentNext)
        }
    }

    await next()
}
