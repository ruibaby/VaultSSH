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

    // This version and its transitive dependencies are reviewed together.
    static let compatibleVersion: String = {
        let url = Bundle.module.url(forResource: "package", withExtension: "json", subdirectory: "CLI")!
        let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (manifest["dependencies"] as! [String: String])["@bitwarden/cli"]!
    }()
    static var bridgeURL: URL? { Bundle.module.url(forResource: "bridge", withExtension: "cjs", subdirectory: "CLI") }
    static var nodePath: String? { shellWhich("node") }

    static var cleanEnvironment: [String: String] {
        let allowed = ["HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "BITWARDENCLI_APPDATA_DIR",
                       "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
                       "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE"]
        var result = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        result["PATH"] = loginPATH
        return result
    }

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
            .bridge("version", timeout: 20)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSupported(_ version: String) -> Bool {
        version == compatibleVersion
    }

    func run(_ args: [String], extraEnv: [String: String] = [:], timeout: TimeInterval = 60, cancellation: CLIProcessCancellation? = nil, input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        var environment = Self.cleanEnvironment
        for (key, value) in extraEnv { environment[key] = value }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        if let inputPipe { process.standardInput = inputPipe }
        else { process.standardInput = FileHandle.nullDevice }
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
        defer { watchdog.cancel() }

        if let inputPipe, let input {
            _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                try? inputPipe.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
                throw error
            }
        }

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
        let output = try bridge("status", timeout: 20)
        guard let data = output.data(using: .utf8) else {
            throw CLIError.failed(L10n.text("Could not read bw status output."))
        }
        return try JSONDecoder().decode(BWStatus.self, from: data)
    }

    func unlock(password: String, cancellation: CLIProcessCancellation? = nil) throws -> String {
        let output = try bridge("unlock", credentials: ["password": password], cancellation: cancellation)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func bridge(_ operation: String, credentials: [String: String] = [:], timeout: TimeInterval = 60,
                cancellation: CLIProcessCancellation? = nil) throws -> String {
        guard let node = Self.nodePath, let script = Self.bridgeURL else {
            throw CLIError.failed(L10n.text("Install Node.js and the supported npm CLI to use secure vault access."))
        }
        let input = try JSONEncoder().encode(credentials)
        guard input.count <= 65_536 else { throw CLIError.failed(L10n.text("The credential input is too large.")) }
        do {
            return try BitwardenCLI(path: node).run([script.path, path, operation], timeout: timeout,
                                                    cancellation: cancellation, input: input)
        } catch is CancellationError { throw CancellationError() }
        catch { throw CLIError.failed(L10n.text("Secure CLI access failed. Check your CLI installation, login, password and network.")) }
    }
}

// Written by one pipe reader, then read only after its DispatchGroup completes.
private final class CLIOutput: @unchecked Sendable {
    var data = Data()
}
