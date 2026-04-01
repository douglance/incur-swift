/// Config schema generation for the incur framework.
///
/// Generates JSON Schema describing the valid config file structure
/// from the CLI's command tree and root options. This allows editors and
/// validators to provide autocompletion and validation for config files.
///
/// Also generates per-command JSON Schema for `--schema` output.
///
/// Ported from `config_schema.rs`.

/// Generates a JSON Schema for config files from the command tree.
///
/// The returned schema has the shape:
///
/// ```json
/// {
///   "type": "object",
///   "additionalProperties": false,
///   "properties": {
///     "$schema": { "type": "string" },
///     "options": { ... },
///     "commands": { ... }
///   }
/// }
/// ```
///
/// - `options` is populated from `rootOptions` field metadata.
/// - `commands` is populated recursively from the command tree, with each
///   leaf command contributing its own `options` sub-object.
public func generateConfigSchema(
    commands: [String: CommandEntry],
    rootOptions: [FieldMeta]
) -> JSONValue {
    var node = buildConfigNode(commands: commands, options: rootOptions)

    // Insert $schema property at the root level.
    if case .object(var obj) = node {
        if var propsMap = obj["properties"]?.objectValue {
            propsMap["$schema"] = .object(["type": .string("string")])
            obj["properties"] = .object(propsMap)
        } else {
            var propsMap = OrderedMap()
            propsMap["$schema"] = .object(["type": .string("string")])
            obj["properties"] = .object(propsMap)
        }
        node = .object(obj)
    }

    return node
}

/// Generates a JSON Schema for a single command's input (args + options).
///
/// The returned schema describes the shape of the command's parameters:
///
/// ```json
/// {
///   "type": "object",
///   "properties": {
///     "<arg_name>": { "type": "string", ... },
///     "<option_name>": { "type": "number", ... }
///   },
///   "required": ["<required_arg>"]
/// }
/// ```
public func generateCommandSchema(command: CommandDef) -> JSONValue {
    var properties = OrderedMap()
    var required: [JSONValue] = []

    // Add args
    for field in command.argsFields {
        properties[field.cliName] = fieldToSchemaProperty(field)
        if field.required {
            required.append(.string(field.cliName))
        }
    }

    // Add options
    for field in command.optionsFields {
        properties[field.cliName] = fieldToSchemaProperty(field)
        if field.required {
            required.append(.string(field.cliName))
        }
    }

    var schema = OrderedMap()
    schema["type"] = .string("object")
    if !properties.isEmpty {
        schema["properties"] = .object(properties)
    }
    if !required.isEmpty {
        schema["required"] = .array(required)
    }

    return .object(schema)
}

// MARK: - Internal Helpers

/// Builds a JSON Schema node for a command level.
///
/// Each level can have:
/// - An `options` property (from `FieldMeta` slices)
/// - A `commands` property (from subcommands in the tree)
private func buildConfigNode(commands: [String: CommandEntry], options: [FieldMeta]) -> JSONValue {
    var properties = OrderedMap()

    // Add `options` property from the options schema fields.
    if !options.isEmpty {
        let optionProps = fieldsToSchemaProperties(options)
        if !optionProps.isEmpty {
            var optionsSchema = OrderedMap()
            optionsSchema["type"] = .string("object")
            optionsSchema["additionalProperties"] = .bool(false)
            optionsSchema["properties"] = .object(optionProps)
            properties["options"] = .object(optionsSchema)
        }
    }

    // Add `commands` property with subcommand namespaces.
    var commandProps = OrderedMap()
    for (name, entry) in commands.sorted(by: { $0.key < $1.key }) {
        switch entry {
        case .leaf(let def):
            commandProps[name] = buildConfigNode(commands: [:], options: def.optionsFields)
        case .fetchGateway:
            // Fetch gateways don't have config schema options
            break
        case .group(_, let subCommands, _, _):
            commandProps[name] = buildConfigNode(commands: subCommands, options: [])
        }
    }

    if !commandProps.isEmpty {
        var commandsSchema = OrderedMap()
        commandsSchema["type"] = .string("object")
        commandsSchema["additionalProperties"] = .bool(false)
        commandsSchema["properties"] = .object(commandProps)
        properties["commands"] = .object(commandsSchema)
    }

    var node = OrderedMap()
    node["type"] = .string("object")
    node["additionalProperties"] = .bool(false)
    if !properties.isEmpty {
        node["properties"] = .object(properties)
    }

    return .object(node)
}

/// Converts a slice of `FieldMeta` into JSON Schema properties.
private func fieldsToSchemaProperties(_ fields: [FieldMeta]) -> OrderedMap {
    var props = OrderedMap()

    for field in fields {
        props[field.cliName] = fieldToSchemaProperty(field)
    }

    return props
}

/// Converts a single `FieldMeta` into a JSON Schema property.
private func fieldToSchemaProperty(_ field: FieldMeta) -> JSONValue {
    var prop = OrderedMap()

    switch field.fieldType {
    case .string:
        prop["type"] = .string("string")
    case .number:
        prop["type"] = .string("number")
    case .boolean:
        prop["type"] = .string("boolean")
    case .array(let inner):
        prop["type"] = .string("array")
        var items = OrderedMap()
        items["type"] = .string(fieldTypeToSchemaType(inner))
        prop["items"] = .object(items)
    case .enum(let values):
        prop["type"] = .string("string")
        prop["enum"] = .array(values.map { .string($0) })
    case .count:
        prop["type"] = .string("number")
    case .value:
        // Any JSON value -- no type constraint
        break
    }

    if let desc = field.description {
        prop["description"] = .string(desc)
    }

    if let defaultValue = field.defaultValue {
        prop["default"] = defaultValue
    }

    return .object(prop)
}

/// Maps a `FieldType` to its JSON Schema type string.
private func fieldTypeToSchemaType(_ ft: FieldType) -> String {
    switch ft {
    case .string: return "string"
    case .number, .count: return "number"
    case .boolean: return "boolean"
    case .array: return "array"
    case .enum: return "string"
    case .value: return "object"
    }
}
