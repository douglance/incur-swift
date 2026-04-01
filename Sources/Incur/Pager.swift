/// Pager helpers for human-facing CLI output.
///
/// Ported from `pager.rs`.

import Foundation

/// Returns `true` when stdout is interactive and paging makes sense.
public func stdoutIsInteractive() -> Bool {
    #if canImport(Darwin)
    return isatty(fileno(stdout)) != 0
    #elseif canImport(Glibc)
    return isatty(fileno(stdout)) != 0
    #else
    return false
    #endif
}

/// Attempts to write `output` to the configured pager.
///
/// Respects `$PAGER` when set, otherwise falls back to `less -FRX`.
/// Returns `true` when a pager was successfully started and completed,
/// `false` when no pager could be launched.
public func pageOutput(_ output: String) -> Bool {
    let pagerEnv = ProcessInfo.processInfo.environment["PAGER"]
    let hasPagerEnv = pagerEnv != nil && !pagerEnv!.trimmingCharacters(in: .whitespaces).isEmpty

    let process = Process()

    if hasPagerEnv {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", pagerEnv!]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/less")
        process.arguments = ["-FRX"]
    }

    let pipe = Pipe()
    process.standardInput = pipe

    do {
        try process.run()
    } catch {
        return false
    }

    let data = output.data(using: .utf8) ?? Data()
    // Write to pipe and close; ignore broken pipe errors
    do {
        try pipe.fileHandleForWriting.write(contentsOf: data)
    } catch {
        // Broken pipe is expected if pager exits early
    }
    pipe.fileHandleForWriting.closeFile()

    process.waitUntilExit()
    return process.terminationStatus == 0
}
