import Foundation
import Darwin

enum ControlStream {
    // FileHandle.read(upToCount:) can wait for a full buffer on a pipe. POSIX
    // read returns the bytes currently available, so a small approval arrives
    // immediately while the helper keeps its output stream open.
    static func read(from output: FileHandle, receive: @Sendable (ControlEvent) async -> Void) async throws {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(output.fileDescriptor, &chunk, chunk.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            buffer.append(contentsOf: chunk[..<count])
            while let end = buffer.firstIndex(of: 0x0A) {
                let data = Data(buffer[..<end])
                buffer.removeSubrange(...end)
                let message = try JSONDecoder().decode(ControlEvent.self, from: data)
                await receive(message)
            }
            if buffer.count > 4_194_304 { throw CLIError.failed(L10n.text("The agent message is too large.")) }
        }
    }
}
