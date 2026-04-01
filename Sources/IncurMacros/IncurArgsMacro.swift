/// `@IncurArgs` macro — generates `IncurSchema` conformance for positional arguments.
///
/// Walks struct members (stored properties only), generates a `FieldMeta` for each,
/// and synthesizes `fields()` and `fromRaw(_:)` methods.
///
/// Port of `incur-macros/src/args.rs`.

import SwiftSyntax
import SwiftSyntaxMacros

public struct IncurArgsMacro: MemberMacro, ExtensionMacro {

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) else {
            throw MacroError("@IncurArgs can only be applied to structs")
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

            // Skip computed properties (those with accessors that aren't simple storage)
            if let accessorBlock = binding.accessorBlock {
                // If it has explicit get/set, it's computed
                if accessorBlock.accessors.is(AccessorDeclListSyntax.self) {
                    continue
                }
            }

            let fieldName = pattern.identifier.text
            let fieldType = typeAnnotation.type
            let cliName = snakeToKebab(fieldName)
            let description = docDescription(from: DeclSyntax(member.decl))
            let isOptional = isOptionalType(fieldType)
            let required = !isOptional
            let fieldTypeExpr = fieldTypeExpression(for: fieldType)

            let descExpr = description.map { "\"\($0)\"" } ?? "nil"

            let entry = "FieldMeta(\n"
                + "            name: \"\(fieldName)\",\n"
                + "            cliName: \"\(cliName)\",\n"
                + "            description: \(descExpr),\n"
                + "            fieldType: \(fieldTypeExpr),\n"
                + "            required: \(required),\n"
                + "            defaultValue: nil,\n"
                + "            alias: nil,\n"
                + "            deprecated: false,\n"
                + "            envName: nil\n"
                + "        )"
            fieldMetaEntries.append(entry)

            // Generate fromRaw assignment
            let assignment = generateFromRawAssignment(
                fieldName: fieldName,
                fieldType: fieldType,
                isOptional: isOptional
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
            return Self(\(raw: fieldMetaEntries.isEmpty ? "" : generateInitArgs(members: members)))
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

private func generateFromRawAssignment(
    fieldName: String,
    fieldType: TypeSyntax,
    isOptional: Bool
) -> String {
    let effective = effectiveType(fieldType)

    if isOptional {
        return generateOptionalExtraction(fieldName: fieldName, innerType: effective)
    }

    if isArrayType(effective) {
        return generateArrayExtraction(fieldName: fieldName, type: effective)
    }

    return generateRequiredExtraction(fieldName: fieldName, type: effective)
}

private func generateOptionalExtraction(fieldName: String, innerType: TypeSyntax) -> String {
    let typeName = typeIdentName(innerType)
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
        return "let \(fieldName): \(typeName)? = nil // unsupported type"
    }
}

private func generateRequiredExtraction(fieldName: String, type: TypeSyntax) -> String {
    let typeName = typeIdentName(type)
    switch typeName {
    case "String":
        return "guard let \(fieldName) = raw[\"\(fieldName)\"]?.stringValue else {\n"
            + "        throw ValidationError(message: \"Missing required argument: \(fieldName)\")\n"
            + "    }"
    case "Int", "Int8", "Int16", "Int32", "Int64",
         "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
        return "guard let _\(fieldName)_raw = raw[\"\(fieldName)\"]?.intValue else {\n"
            + "        throw ValidationError(message: \"Missing required argument: \(fieldName)\")\n"
            + "    }\n"
            + "    let \(fieldName) = \(typeName)(_\(fieldName)_raw)"
    case "Double", "Float":
        return "guard let _\(fieldName)_raw = raw[\"\(fieldName)\"]?.doubleValue else {\n"
            + "        throw ValidationError(message: \"Missing required argument: \(fieldName)\")\n"
            + "    }\n"
            + "    let \(fieldName) = \(typeName)(_\(fieldName)_raw)"
    case "Bool":
        return "let \(fieldName) = raw[\"\(fieldName)\"]?.boolValue ?? false"
    default:
        return "let \(fieldName): \(typeName)? = nil // unsupported type"
    }
}

private func generateArrayExtraction(fieldName: String, type: TypeSyntax) -> String {
    // For arrays, extract from JSONValue array
    return """
    let \(fieldName) = raw["\(fieldName)"]?.arrayValue?.compactMap { $0.stringValue } ?? []
    """
}

private func generateInitArgs(members: MemberBlockItemListSyntax) -> String {
    var args: [String] = []
    for member in members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              varDecl.bindingSpecifier.text == "var" || varDecl.bindingSpecifier.text == "let",
              let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              binding.typeAnnotation != nil else {
            continue
        }
        // Skip computed properties
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

private func typeIdentName(_ type: TypeSyntax) -> String {
    if let identType = type.as(IdentifierTypeSyntax.self) {
        return identType.name.text
    }
    return "Any"
}

// MARK: - Error

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}
