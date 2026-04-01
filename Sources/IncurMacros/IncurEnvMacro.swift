/// `@IncurEnv` macro — generates `IncurSchema` conformance for environment-variable bindings.
///
/// Supports `@Incur(env:)` for explicit env var names and `@Incur(default:)` for defaults.
/// Falls back to SCREAMING_SNAKE_CASE of the field name when no `env:` is provided.
///
/// Port of `incur-macros/src/env.rs`.

import SwiftSyntax
import SwiftSyntaxMacros

public struct IncurEnvMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            throw MacroError("@IncurEnv can only be applied to structs")
        }

        let members = declaration.memberBlock.members
        var fieldMetaEntries: [String] = []
        var fieldAssignments: [String] = []

        for member in members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.bindingSpecifier.text == "var" || varDecl.bindingSpecifier.text == "let",
                  let binding = varDecl.bindings.first,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let typeAnnotation = binding.typeAnnotation else {
                continue
            }

            // Skip computed properties
            if let accessorBlock = binding.accessorBlock {
                if accessorBlock.accessors.is(AccessorDeclListSyntax.self) {
                    continue
                }
            }

            let fieldName = pattern.identifier.text
            let fieldType = typeAnnotation.type
            let cliName = snakeToKebab(fieldName)
            let description = docDescription(from: DeclSyntax(member.decl))
            let attrs = parseIncurAttribute(from: varDecl.attributes)

            let isOptional = isOptionalType(fieldType)
            let hasDefault = attrs.defaultValue != nil
            let required = !isOptional && !hasDefault

            let fieldTypeExpr = fieldTypeExpression(for: fieldType)
            let descExpr = description.map { "\"\($0)\"" } ?? "nil"
            let defaultExpr = defaultValueExpression(attrs)

            // Use explicit env name or fall back to SCREAMING_SNAKE_CASE
            let envName = attrs.envName ?? toScreamingSnake(fieldName)

            let entry = "FieldMeta(\n"
                + "            name: \"\(fieldName)\",\n"
                + "            cliName: \"\(cliName)\",\n"
                + "            description: \(descExpr),\n"
                + "            fieldType: \(fieldTypeExpr),\n"
                + "            required: \(required),\n"
                + "            defaultValue: \(defaultExpr),\n"
                + "            alias: nil,\n"
                + "            deprecated: false,\n"
                + "            envName: \"\(envName)\"\n"
                + "        )"
            fieldMetaEntries.append(entry)

            // Generate fromRaw assignment
            let assignment = generateEnvFromRawAssignment(
                fieldName: fieldName,
                fieldType: fieldType,
                isOptional: isOptional,
                attrs: attrs
            )
            fieldAssignments.append(assignment)
        }

        let fieldsBody = fieldMetaEntries.joined(separator: ",\n        ")
        let assignmentsBody = fieldAssignments.joined(separator: "\n    ")

        let fieldsDecl: DeclSyntax = """
        static func fields() -> [FieldMeta] {
            [
                \(raw: fieldsBody)
            ]
        }
        """

        let fromRawDecl: DeclSyntax = """
        static func fromRaw(_ raw: OrderedMap) throws -> Self {
            \(raw: assignmentsBody)
            return Self(\(raw: fieldMetaEntries.isEmpty ? "" : generateEnvInitArgs(members: members)))
        }
        """

        return [fieldsDecl, fromRawDecl]
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let ext: DeclSyntax = """
        extension \(type.trimmed): IncurSchema {}
        """
        return [ext.cast(ExtensionDeclSyntax.self)]
    }
}

// MARK: - Helpers

private func generateEnvFromRawAssignment(
    fieldName: String,
    fieldType: TypeSyntax,
    isOptional: Bool,
    attrs: IncurAttr
) -> String {
    let effective = effectiveType(fieldType)
    let typeName = envTypeIdentName(effective)

    if isOptional {
        return generateOptionalEnvExtraction(fieldName: fieldName, typeName: typeName)
    }

    if let defaultValue = attrs.defaultValue, let defaultKind = attrs.defaultKind {
        return generateDefaultEnvExtraction(
            fieldName: fieldName, typeName: typeName,
            defaultValue: defaultValue, defaultKind: defaultKind
        )
    }

    return generateRequiredEnvExtraction(fieldName: fieldName, typeName: typeName)
}

private func generateOptionalEnvExtraction(fieldName: String, typeName: String) -> String {
    switch typeName {
    case "String":
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue"
    case "Int", "Int8", "Int16", "Int32", "Int64",
         "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.intValue.map { \(typeName)($0) }"
    case "Double", "Float":
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.doubleValue.map { \(typeName)($0) }"
    case "Bool":
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.boolValue"
    default:
        return "let \(fieldName): \(typeName)? = nil"
    }
}

private func generateRequiredEnvExtraction(fieldName: String, typeName: String) -> String {
    switch typeName {
    case "String":
        return "guard let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue else {\n"
            + "        throw ValidationError(message: \"Missing required env var: \(fieldName)\")\n"
            + "    }"
    case "Int", "Int8", "Int16", "Int32", "Int64",
         "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
        return "guard let _\(fieldName)_raw = raw[\"\(fieldName)\"]?.intValue else {\n"
            + "        throw ValidationError(message: \"Missing required env var: \(fieldName)\")\n"
            + "    }\n"
            + "    let \(fieldName) = \(typeName)(_\(fieldName)_raw)"
    case "Double", "Float":
        return "guard let _\(fieldName)_raw = raw[\"\(fieldName)\"]?.doubleValue else {\n"
            + "        throw ValidationError(message: \"Missing required env var: \(fieldName)\")\n"
            + "    }\n"
            + "    let \(fieldName) = \(typeName)(_\(fieldName)_raw)"
    default:
        return "guard let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue else {\n"
            + "        throw ValidationError(message: \"Missing required env var: \(fieldName)\")\n"
            + "    }"
    }
}

private func generateDefaultEnvExtraction(
    fieldName: String, typeName: String,
    defaultValue: String, defaultKind: DefaultKind
) -> String {
    switch (typeName, defaultKind) {
    case ("String", _):
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue ?? \"\(defaultValue)\""
    case (_, .int):
        return "let \(fieldName) = \(typeName)(raw[\"\(fieldName)\"]?.intValue ?? \(defaultValue))"
    case (_, .float):
        return "let \(fieldName) = \(typeName)(raw[\"\(fieldName)\"]?.doubleValue ?? \(defaultValue))"
    case (_, .bool):
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.boolValue ?? \(defaultValue)"
    default:
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue ?? \"\(defaultValue)\""
    }
}

private func generateEnvInitArgs(members: MemberBlockItemListSyntax) -> String {
    var args: [String] = []
    for member in members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              varDecl.bindingSpecifier.text == "var" || varDecl.bindingSpecifier.text == "let",
              let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.typeAnnotation != nil else {
            continue
        }
        if let accessorBlock = binding.accessorBlock {
            if accessorBlock.accessors.is(AccessorDeclListSyntax.self) {
                continue
            }
        }
        let name = pattern.identifier.text
        args.append("\(name): \(name)")
    }
    return args.joined(separator: ", ")
}

private func envTypeIdentName(_ type: TypeSyntax) -> String {
    if let identType = type.as(IdentifierTypeSyntax.self) {
        return identType.name.text
    }
    return "Any"
}
