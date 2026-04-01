/// `@Incur(...)` peer macro — a no-op marker that is parsed by the struct-level macros.
///
/// This macro produces no additional declarations. Its arguments are read
/// by `IncurOptionsMacro` and `IncurEnvMacro` during expansion.

import SwiftSyntax
import SwiftSyntaxMacros

public struct IncurFieldMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // No-op: the @Incur attribute is parsed by the struct-level macros.
        return []
    }
}
