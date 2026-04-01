import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct IncurMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        IncurArgsMacro.self,
        IncurOptionsMacro.self,
        IncurEnvMacro.self,
        IncurFieldMacro.self,
    ]
}
