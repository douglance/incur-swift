/// `@IncurOptions` macro — generates `IncurSchema` conformance for named options/flags.
///
/// Supports `@Incur(alias:)`, `@Incur(default:)`, `@Incur(count:)`, and
/// `@Incur(deprecated:)` attributes on fields.
///
/// Port of `incur-macros/src/options.rs`.

import SwiftSyntax
import SwiftSyntaxMacros

public struct IncurOptionsMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            throw MacroError("@IncurOptions can only be applied to structs")
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
            let isArray = isArrayType(effectiveType(fieldType))
            let isBool = isBoolType(fieldType) || isBoolType(effectiveType(fieldType))
            let hasDefault = attrs.defaultValue != nil

            // A field is required if it is not Optional<T>, not Array, not Bool,
            // has no default, and is not a count flag.
            let required = !isOptional && !isArray && !isBool && !hasDefault && !attrs.count

            // If the field is marked as count, override the field type
            let fieldTypeExpr: String
            if attrs.count {
                fieldTypeExpr = ".count"
            } else {
                fieldTypeExpr = fieldTypeExpression(for: fieldType)
            }

            let descExpr = description.map { "\"\($0)\"" } ?? "nil"
            let defaultExpr = defaultValueExpression(attrs)

            let aliasExpr: String
            if let alias = attrs.alias {
                aliasExpr = "Character(\"\(alias)\")"
            } else {
                aliasExpr = "nil"
            }

            let entry = "FieldMeta(\n"
                + "            name: \"\(fieldName)\",\n"
                + "            cliName: \"\(cliName)\",\n"
                + "            description: \(descExpr),\n"
                + "            fieldType: \(fieldTypeExpr),\n"
                + "            required: \(required),\n"
                + "            defaultValue: \(defaultExpr),\n"
                + "            alias: \(aliasExpr),\n"
                + "            deprecated: \(attrs.deprecated),\n"
                + "            envName: nil\n"
                + "        )"
            fieldMetaEntries.append(entry)

            // Generate fromRaw assignment
            let assignment = generateOptionsFromRawAssignment(
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
            return Self(\(raw: fieldMetaEntries.isEmpty ? "" : generateOptionsInitArgs(members: members)))
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

private func generateOptionsFromRawAssignment(
    fieldName: String,
    fieldType: TypeSyntax,
    isOptional: Bool,
    attrs: IncurAttr
) -> String {
    let effective = effectiveType(fieldType)
    let typeName = optionsTypeIdentName(effective)

    if attrs.count {
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.intValue ?? 0"
    }

    if isOptional {
        return generateOptionalOptionsExtraction(fieldName: fieldName, typeName: typeName)
    }

    if isArrayType(effective) {
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.arrayValue?.compactMap { $0.stringValue } ?? []"
    }

    if typeName == "Bool" {
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.boolValue ?? false"
    }

    if let defaultValue = attrs.defaultValue, let defaultKind = attrs.defaultKind {
        return generateDefaultExtraction(
            fieldName: fieldName, typeName: typeName,
            defaultValue: defaultValue, defaultKind: defaultKind
        )
    }

    return generateRequiredOptionsExtraction(fieldName: fieldName, typeName: typeName)
}

private func generateOptionalOptionsExtraction(fieldName: String, typeName: String) -> String {
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

private func generateRequiredOptionsExtraction(fieldName: String, typeName: String) -> String {
    switch typeName {
    case "String":
        return "guard let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue else {\n"
            + "        throw ValidationError(message: \"Missing required option: \(fieldName)\")\n"
            + "    }"
    case "Int", "Int8", "Int16", "Int32", "Int64",
         "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
        return "guard let _\(fieldName)_raw = raw[\"\(fieldName)\"]?.intValue else {\n"
            + "        throw ValidationError(message: \"Missing required option: \(fieldName)\")\n"
            + "    }\n"
            + "    let \(fieldName) = \(typeName)(_\(fieldName)_raw)"
    case "Double", "Float":
        return "guard let _\(fieldName)_raw = raw[\"\(fieldName)\"]?.doubleValue else {\n"
            + "        throw ValidationError(message: \"Missing required option: \(fieldName)\")\n"
            + "    }\n"
            + "    let \(fieldName) = \(typeName)(_\(fieldName)_raw)"
    default:
        return "guard let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue else {\n"
            + "        throw ValidationError(message: \"Missing required option: \(fieldName)\")\n"
            + "    }"
    }
}

private func generateDefaultExtraction(
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

private func generateOptionsInitArgs(members: MemberBlockItemListSyntax) -> String {
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

private func optionsTypeIdentName(_ type: TypeSyntax) -> String {
    if let identType = type.as(IdentifierTypeSyntax.self) {
        return identType.name.text
    }
    return "Any"
}
