/// IncurGen — codegen tool that emits `Incur.generated.swift` from a CLI manifest.
///
/// Usage:
///   IncurGen --help
///   IncurGen --manifest <path>            # read JSON manifest from file
///   IncurGen --manifest -                 # read JSON manifest from stdin
///   IncurGen --output <path>              # write to file (default stdout)
///
/// Manifest shape:
///   { "name": "myapp", "commands": [
///       { "name": "add", "argsFields": [...], "optionsFields": [...] }
///   ] }
///
/// Mirrors TS `Typegen.generate(input, output)`. Uses string templating only —
/// no swift-syntax dependency — so downstream consumers don't pay for parsing.

import Foundation
import Incur

let args = Array(CommandLine.arguments.dropFirst())

func printHelp() {
    let help = """
    IncurGen — generate `Incur.generated.swift` typed CTA helpers.

    Usage:
      IncurGen [--manifest <path|->] [--output <path>] [--help]

    Options:
      --manifest <path>   JSON manifest path (or `-` for stdin).
                          Defaults to stdin.
      --output <path>     Output file (defaults to stdout).
      --help              Show this help.

    Manifest shape:
      { "name": "myapp",
        "commands": [
          { "name": "cmd", "argsFields": [...], "optionsFields": [...] }
        ]
      }
    """
    print(help)
}

if args.contains("--help") || args.contains("-h") {
    printHelp()
    exit(0)
}

var manifestPath: String? = nil
var outputPath: String? = nil
var i = 0
while i < args.count {
    let token = args[i]
    if token == "--manifest", i + 1 < args.count {
        manifestPath = args[i + 1]
        i += 2
    } else if token == "--output", i + 1 < args.count {
        outputPath = args[i + 1]
        i += 2
    } else {
        i += 1
    }
}

let manifestData: Data
let resolvedManifest = manifestPath ?? "-"
if resolvedManifest == "-" {
    manifestData = FileHandle.standardInput.readDataToEndOfFile()
} else {
    let url = URL(fileURLWithPath: resolvedManifest)
    do {
        manifestData = try Data(contentsOf: url)
    } catch {
        fputs("IncurGen: failed to read \(resolvedManifest): \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

guard let manifestStr = String(data: manifestData, encoding: .utf8),
      let manifest = JSONValue.parse(manifestStr) else {
    fputs("IncurGen: manifest is not valid JSON\n", stderr)
    exit(1)
}

guard let source = generateSwiftSource(manifest: manifest) else {
    fputs("IncurGen: manifest must have `name` and `commands` fields\n", stderr)
    exit(1)
}

if let outputPath {
    do {
        try source.write(toFile: outputPath, atomically: true, encoding: .utf8)
    } catch {
        fputs("IncurGen: failed to write \(outputPath): \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    print(source)
}
