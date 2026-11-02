import Foundation
import Darwin

enum CLIError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

struct BitwardenCLI: Sendable {
    let path: String

    static let minimumVersion = "2024.12.0"

    // 2026.3.0+ requires the official server's accountCryptographicState,
    // which Vaultwarden does not provide. Keep the last compatible release.
    static let compatibleVersion = "2026.2.0"

    static var loginPATH: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        } catch {}
        return "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    static func shellWhich(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }

    static func candidatePaths(override: String) -> [String] {
        var paths: [String] = []
        if !override.isEmpty { return [(override as NSString).expandingTildeInPath] }
        paths.append(AppPaths.localCLI.path)
        paths.append("/opt/homebrew/bin/bw")
        paths.append("/usr/local/bin/bw")
        if let which = shellWhich("bw") { paths.append(which) }
        paths.append(NSHomeDirectory() + "/.vite-plus/bin/bw")

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    static func resolve(override: String) -> (path: String, version: String)? {
        var fallback: (path: String, version: String)?
        for candidate in candidatePaths(override: override) {
            guard FileManager.default.isExecutableFile(atPath: candidate),
                  let version = version(at: candidate) else { continue }
            if fallback == nil { fallback = (candidate, version) }
            if isSupported(version) { return (candidate, version) }
        }
        return fallback
    }

    static func version(at path: String) -> String? {
        try? BitwardenCLI(path: path)
            .run(["--version"], timeout: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSupported(_ version: String) -> Bool {
        compare(version, minimumVersion) >= 0
    }

    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    func run(_ args: [String], extraEnv: [String: String] = [:], timeout: TimeInterval = 60, cancellation: CLIProcessCancellation? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.loginPATH
        for (key, value) in extraEnv { environment[key] = value }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let cancellation { try cancellation.launch(process) }
        else { try process.run() }

        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let errorOutput = CLIOutput()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global().async {
            errorOutput.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        readers.wait()
        let stderrData = errorOutput.data
        process.waitUntilExit()
        watchdog.cancel()
        try cancellation?.checkCancellation()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError.failed(message.isEmpty ? L10n.text("bw exited with code %@", String(process.terminationStatus)) : message)
        }
        return stdout
    }

    func status() throws -> BWStatus {
        let output = try run(["--nointeraction", "status"], timeout: 20)
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed(L10n.text("Could not read bw status output."))
        }
        return try JSONDecoder().decode(BWStatus.self, from: data)
    }

    func unlock(password: String, cancellation: CLIProcessCancellation? = nil) throws -> String {
        let output = try run(
            ["--nointeraction", "unlock", "--raw", "--passwordenv", "BW_PASSWORD"],
            extraEnv: ["BW_PASSWORD": password],
            timeout: 60, cancellation: cancellation
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Written by one pipe reader, then read only after its DispatchGroup completes.
private final class CLIOutput: @unchecked Sendable {
    var data = Data()
}
