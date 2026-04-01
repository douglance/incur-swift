/// Shell completion generation for bash, zsh, fish, and nushell.
///
/// Ported from `completions.rs`.

/// Supported shell environments for completion.
public enum Shell: String, Sendable, CaseIterable {
    case bash, zsh, fish, nushell

    public static func from(_ s: String) -> Shell? {
        switch s {
        case "bash": return .bash
        case "zsh": return .zsh
        case "fish": return .fish
        case "nushell": return .nushell
        default: return nil
        }
    }
}

/// A completion candidate with an optional description.
public struct CompletionCandidate: Sendable {
    public let value: String
    public let description: String?
    public let noSpace: Bool

    public init(value: String, description: String? = nil, noSpace: Bool = false) {
        self.value = value
        self.description = description
        self.noSpace = noSpace
    }
}

/// A command entry in the command tree for completions.
public struct CompletionCommandEntry: Sendable {
    public let isGroup: Bool
    public let description: String?
    public let commands: [String: CompletionCommandEntry]
    public let optionsFields: [FieldMeta]
    public let aliases: [String: Character]

    public init(
        isGroup: Bool = false,
        description: String? = nil,
        commands: [String: CompletionCommandEntry] = [:],
        optionsFields: [FieldMeta] = [],
        aliases: [String: Character] = [:]
    ) {
        self.isGroup = isGroup
        self.description = description
        self.commands = commands
        self.optionsFields = optionsFields
        self.aliases = aliases
    }
}

/// A root command definition for completions.
public struct CompletionCommandDef: Sendable {
    public let optionsFields: [FieldMeta]
    public let aliases: [String: Character]

    public init(optionsFields: [FieldMeta] = [], aliases: [String: Character] = [:]) {
        self.optionsFields = optionsFields
        self.aliases = aliases
    }
}

// MARK: - Shell Registration Scripts

/// Generates a shell hook script that registers dynamic completions.
public func registerCompletion(shell: Shell, name: String) -> String {
    switch shell {
    case .bash: return bashRegister(name)
    case .zsh: return zshRegister(name)
    case .fish: return fishRegister(name)
    case .nushell: return nushellRegister(name)
    }
}

private func shellIdent(_ name: String) -> String {
    name.map { $0.isLetter || $0.isNumber || $0 == "_" ? String($0) : "_" }.joined()
}

private func bashRegister(_ name: String) -> String {
    let id = shellIdent(name)
    return """
    _incur_complete_\(id)() {
        local IFS=$'\\013'
        local _COMPLETE_INDEX=${COMP_CWORD}
        local _completions
        _completions=( $(
            COMPLETE="bash"
            _COMPLETE_INDEX="$_COMPLETE_INDEX"
            "\(name)" -- "${COMP_WORDS[@]}"
        ) )
        if [[ $? != 0 ]]; then
            unset COMPREPLY
            return
        fi
        local _nospace=false
        COMPREPLY=()
        for _c in "${_completions[@]}"; do
            if [[ "$_c" == *$'\\001' ]]; then
                _nospace=true
                COMPREPLY+=("${_c%$'\\001'}")
            else
                COMPREPLY+=("$_c")
            fi
        done
        if [[ $_nospace == true ]]; then
            compopt -o nospace
        fi
    }
    complete -o default -o bashdefault -o nosort -F _incur_complete_\(id) \(name)
    """
}

private func zshRegister(_ name: String) -> String {
    let id = shellIdent(name)
    return """
    #compdef \(name)
    _incur_complete_\(id)() {
        local completions=("${(@f)$(
            _COMPLETE_INDEX=$(( CURRENT - 1 ))
            COMPLETE="zsh"
            "\(name)" -- "${words[@]}" 2>/dev/null
        )}")
        if [[ -n $completions ]]; then
            _describe 'values' completions -S ''
        fi
    }
    compdef _incur_complete_\(id) \(name)
    """
}

private func fishRegister(_ name: String) -> String {
    return """
    complete --keep-order --exclusive --command \(name) \\
        --arguments "(COMPLETE=fish \(name) -- (commandline --current-process --tokenize --cut-at-cursor) (commandline --current-token))"
    """
}

private func nushellRegister(_ name: String) -> String {
    let id = shellIdent(name)
    return """
    # External completer for \(name)
    # Add to $env.config.completions.external.completer or use in a dispatch completer.
    let _incur_complete_\(id) = {|spans|
        COMPLETE=nushell \(name) -- ...$spans | from json
    }
    """
}

// MARK: - Completion Computation

/// Computes completion candidates for the given argv words and cursor index.
public func computeCompletions(
    commands: [String: CompletionCommandEntry],
    rootCommand: CompletionCommandDef?,
    argv: [String],
    index: Int
) -> [CompletionCandidate] {
    let current = index < argv.count ? argv[index] : ""

    // Walk argv to resolve scope
    var scopeCommands = commands
    var scopeLeaf: (optionsFields: [FieldMeta], aliases: [String: Character])? =
        rootCommand.map { ($0.optionsFields, $0.aliases) }

    for i in 0..<index {
        guard i < argv.count else { break }
        let token = argv[i]
        if token.hasPrefix("-") { continue }
        if let entry = scopeCommands[token] {
            if entry.isGroup {
                scopeCommands = entry.commands
                scopeLeaf = nil
            } else {
                scopeLeaf = (entry.optionsFields, entry.aliases)
                break
            }
        }
    }

    var candidates: [CompletionCandidate] = []

    // If cursor word starts with '-', suggest options
    if current.hasPrefix("-") {
        if let leaf = scopeLeaf {
            for field in leaf.optionsFields {
                let flag = "--\(field.cliName)"
                if flag.hasPrefix(current) {
                    candidates.append(CompletionCandidate(
                        value: flag,
                        description: field.description
                    ))
                }
            }
            for (name, alias) in leaf.aliases {
                let flag = "-\(alias)"
                if flag.hasPrefix(current) {
                    let desc = leaf.optionsFields.first { $0.name == name }?.description
                    candidates.append(CompletionCandidate(value: flag, description: desc))
                }
            }
        }
        return candidates
    }

    // Check if previous token is a non-boolean option expecting a value
    if index > 0 {
        let prev = index - 1 < argv.count ? argv[index - 1] : ""
        if prev.hasPrefix("-"), let leaf = scopeLeaf {
            if let fieldName = resolveOptionName(prev, leaf: leaf) {
                if let values = possibleValues(fieldName, fields: leaf.optionsFields) {
                    for v in values where v.hasPrefix(current) {
                        candidates.append(CompletionCandidate(value: v))
                    }
                    return candidates
                }
                if !isBooleanOption(fieldName, fields: leaf.optionsFields) {
                    return candidates
                }
            }
        }
    }

    // Suggest subcommands
    for (name, entry) in scopeCommands.sorted(by: { $0.key < $1.key }) {
        if name.hasPrefix(current) {
            candidates.append(CompletionCandidate(
                value: name,
                description: entry.description,
                noSpace: entry.isGroup
            ))
        }
    }

    return candidates
}

/// Formats completion candidates into shell-specific output.
public func formatCompletions(shell: Shell, candidates: [CompletionCandidate]) -> String {
    switch shell {
    case .bash:
        return candidates.map { c in
            c.noSpace ? "\(c.value)\u{01}" : c.value
        }.joined(separator: "\u{0B}")

    case .zsh:
        return candidates.map { c in
            let escaped = c.value.replacingOccurrences(of: ":", with: "\\:")
            if let desc = c.description {
                return "\(escaped):\(desc)"
            }
            return escaped
        }.joined(separator: "\n")

    case .fish:
        return candidates.map { c in
            if let desc = c.description {
                return "\(c.value)\t\(desc)"
            }
            return c.value
        }.joined(separator: "\n")

    case .nushell:
        let records: [JSONValue] = candidates.map { c in
            var obj: OrderedMap = ["value": .string(c.value)]
            if let desc = c.description {
                obj["description"] = .string(desc)
            }
            return .object(obj)
        }
        return JSONValue.array(records).toJSON(pretty: false)
    }
}

// MARK: - Internal Helpers

private func resolveOptionName(
    _ token: String,
    leaf: (optionsFields: [FieldMeta], aliases: [String: Character])
) -> String? {
    if token.hasPrefix("--") {
        let raw = String(token.dropFirst(2))
        let snake = toSnake(raw)
        if leaf.optionsFields.contains(where: { $0.name == snake }) { return snake }
        if leaf.optionsFields.contains(where: { $0.name == raw }) { return raw }
        return nil
    } else if token.hasPrefix("-") && token.count == 2 {
        let short = token[token.index(after: token.startIndex)]
        for (name, alias) in leaf.aliases {
            if alias == short { return name }
        }
        return nil
    }
    return nil
}

private func isBooleanOption(_ name: String, fields: [FieldMeta]) -> Bool {
    fields.first { $0.name == name }.map {
        $0.fieldType == .boolean || $0.fieldType == .count
    } ?? false
}

private func possibleValues(_ name: String, fields: [FieldMeta]) -> [String]? {
    guard let field = fields.first(where: { $0.name == name }) else { return nil }
    if case .enum(let values) = field.fieldType { return values }
    return nil
}
