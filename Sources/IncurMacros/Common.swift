/// Shared utilities for the incur Swift macros.
///
/// Provides helpers for extracting doc comments, parsing `@Incur(...)` attributes,
/// mapping Swift types to `FieldType` expressions, and string case conversion.

import SwiftSyntax

// MARK: - Doc Comment Extraction

/// Extracts the concatenated `///` doc-comment text from a member declaration.
///
/// Returns `nil` if no doc comments are present.
func docDescription(from member: DeclSyntax) -> String? {
    let trivia = member.leadingTrivia
    let lines: [String] = trivia.compactMap { piece in
        switch piece {
        case .docLineComment(let text):
            // Strip the leading `/// ` or `///`
            let stripped = text.drop(while: { $0 == "/" })
            return stripped.trimmingCharacters(in: .whitespaces)
        default:
            return nil
        }
    }
    guard !lines.isEmpty else { return nil }
    return lines.joined(separator: " ")
}

// MARK: - Type Inspection

/// Returns `true` if the type syntax represents `Optional<T>` or `T?`.
func isOptionalType(_ type: TypeSyntax) -> Bool {
    // T?
    if type.is(OptionalTypeSyntax.self) {
        return true
    }
    // Optional<T>
    if let identType = type.as(IdentifierTypeSyntax.self),
       identType.name.text == "Optional",
       identType.genericArgumentClause != nil {
        return true
    }
    return false
}

/// Returns `true` if the type syntax represents `[T]` or `Array<T>`.
func isArrayType(_ type: TypeSyntax) -> Bool {
    // [T]
    if type.is(ArrayTypeSyntax.self) {
        return true
    }
    // Array<T>
    if let identType = type.as(IdentifierTypeSyntax.self),
       identType.name.text == "Array",
       identType.genericArgumentClause != nil {
        return true
    }
    return false
}

/// Unwraps `Optional<T>`, `T?`, `[T]`, or `Array<T>` to get the inner type `T`.
///
/// Returns `nil` if the type is not a wrapper type.
func innerType(_ type: TypeSyntax) -> TypeSyntax? {
    // T?
    if let optional = type.as(OptionalTypeSyntax.self) {
        return optional.wrappedType
    }
    // Optional<T>
    if let identType = type.as(IdentifierTypeSyntax.self),
       identType.name.text == "Optional",
       let clause = identType.genericArgumentClause,
       let first = clause.arguments.first {
        return first.argument
    }
    // [T]
    if let arrayType = type.as(ArrayTypeSyntax.self) {
        return arrayType.element
    }
    // Array<T>
    if let identType = type.as(IdentifierTypeSyntax.self),
       identType.name.text == "Array",
       let clause = identType.genericArgumentClause,
       let first = clause.arguments.first {
        return first.argument
    }
    return nil
}

/// Returns the effective type for field type determination.
/// Unwraps Optional<T> first, then checks for Array.
func effectiveType(_ type: TypeSyntax) -> TypeSyntax {
    // Unwrap Optional first
    if isOptionalType(type), let inner = innerType(type) {
        return inner
    }
    return type
}

/// Maps a Swift type name to a FieldType expression string.
///
/// - `String` -> `.string`
/// - `Bool` -> `.boolean`
/// - Numeric types -> `.number`
/// - `[T]` or `Array<T>` -> `.array(<inner>)`
/// - Unknown -> `.value`
func fieldTypeExpression(for type: TypeSyntax) -> String {
    let effective = effectiveType(type)

    // Check for array types
    if isArrayType(effective), let inner = innerType(effective) {
        let innerExpr = scalarFieldTypeExpression(for: inner)
        return ".array(\(innerExpr))"
    }

    return scalarFieldTypeExpression(for: effective)
}

/// Maps a scalar (non-array, non-optional) type to a FieldType expression string.
private func scalarFieldTypeExpression(for type: TypeSyntax) -> String {
    let typeName = typeIdentString(type)
    switch typeName {
    case "String":
        return ".string"
    case "Bool":
        return ".boolean"
    case "Int", "Int8", "Int16", "Int32", "Int64",
         "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
         "Float", "Double":
        return ".number"
    default:
        return ".value"
    }
}

/// Extracts the type name string from a type syntax node.
private func typeIdentString(_ type: TypeSyntax) -> String? {
    if let identType = type.as(IdentifierTypeSyntax.self) {
        return identType.name.text
    }
    return nil
}

// MARK: - String Case Conversion

/// Converts a Swift `camelCase` or `snake_case` identifier to CLI `kebab-case`.
func snakeToKebab(_ name: String) -> String {
    var result = ""
    result.reserveCapacity(name.count)
    for (i, ch) in name.enumerated() {
        if ch == "_" {
            result.append("-")
        } else if ch.isUppercase {
            if i > 0 { result.append("-") }
            result.append(ch.lowercased())
        } else {
            result.append(ch)
        }
    }
    return result
}

/// Converts a Swift `camelCase` or `snake_case` identifier to `SCREAMING_SNAKE_CASE`.
func toScreamingSnake(_ name: String) -> String {
    var result = ""
    result.reserveCapacity(name.count * 2)
    for (i, ch) in name.enumerated() {
        if ch == "_" {
            result.append("_")
        } else if ch.isUppercase {
            if i > 0 { result.append("_") }
            result.append(ch)
        } else {
            result.append(ch.uppercased())
        }
    }
    return result
}

// MARK: - Incur Attribute Parsing

/// Parsed `@Incur(...)` attribute arguments for a single field.
struct IncurAttr {
    /// Short alias character (e.g. `alias: "n"` -> "n").
    var alias: String?
    /// Default value expression as a string literal representation.
    var defaultValue: String?
    /// The type of the default value for correct JSONValue construction.
    var defaultKind: DefaultKind?
    /// Whether the field is a count flag (`@Incur(count: true)`).
    var count: Bool = false
    /// Whether the field is deprecated (`@Incur(deprecated: true)`).
    var deprecated: Bool = false
    /// Environment variable name (`@Incur(env: "VAR_NAME")`).
    var envName: String?
}

/// The kind of a default value literal, for correct code generation.
enum DefaultKind {
    case string
    case int
    case float
    case bool
}

/// Parses `@Incur(...)` attributes from a variable declaration's attributes.
///
/// Looks for attributes whose name is "Incur" and extracts the labeled arguments.
func parseIncurAttribute(from attributes: AttributeListSyntax) -> IncurAttr {
    var result = IncurAttr()

    for element in attributes {
        guard let attr = element.as(AttributeSyntax.self),
              let identType = attr.attributeName.as(IdentifierTypeSyntax.self),
              identType.name.text == "Incur" else {
            continue
        }

        guard let arguments = attr.arguments?.as(LabeledExprListSyntax.self) else {
            continue
        }

        for arg in arguments {
            guard let label = arg.label?.text else { continue }

            switch label {
            case "alias":
                if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                   let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                    result.alias = segment.content.text
                }

            case "default":
                if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                   let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                    result.defaultValue = segment.content.text
                    result.defaultKind = .string
                } else if let intLiteral = arg.expression.as(IntegerLiteralExprSyntax.self) {
                    result.defaultValue = intLiteral.literal.text
                    result.defaultKind = .int
                } else if let floatLiteral = arg.expression.as(FloatLiteralExprSyntax.self) {
                    result.defaultValue = floatLiteral.literal.text
                    result.defaultKind = .float
                } else if let boolLiteral = arg.expression.as(BooleanLiteralExprSyntax.self) {
                    result.defaultValue = boolLiteral.literal.text
                    result.defaultKind = .bool
                }

            case "count":
                if let boolLiteral = arg.expression.as(BooleanLiteralExprSyntax.self),
                   boolLiteral.literal.text == "true" {
                    result.count = true
                }

            case "deprecated":
                if let boolLiteral = arg.expression.as(BooleanLiteralExprSyntax.self),
                   boolLiteral.literal.text == "true" {
                    result.deprecated = true
                }

            case "env":
                if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                   let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
                    result.envName = segment.content.text
                }

            default:
                break
            }
        }
    }

    return result
}

// MARK: - Default Value Code Generation

/// Generates a Swift expression string that constructs the appropriate `JSONValue`
/// for a default value.
func defaultValueExpression(_ attr: IncurAttr) -> String {
    guard let value = attr.defaultValue, let kind = attr.defaultKind else {
        return "nil"
    }
    switch kind {
    case .string:
        return ".string(\"\(value)\")"
    case .int:
        return ".int(\(value))"
    case .float:
        return ".double(\(value))"
    case .bool:
        return value == "true" ? ".bool(true)" : ".bool(false)"
    }
}

// MARK: - Type Checking Helpers

/// Returns `true` if the type's identifier is `Bool`.
func isBoolType(_ type: TypeSyntax) -> Bool {
    if let identType = type.as(IdentifierTypeSyntax.self) {
        return identType.name.text == "Bool"
    }
    return false
}
