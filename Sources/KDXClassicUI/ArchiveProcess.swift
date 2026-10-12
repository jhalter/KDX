import Foundation
import Darwin

/// Runs installed archive tools only. Output stays bounded in memory and termination has a deadline.
enum ArchiveProcess {
    static func run(_ executable: String, arguments: [String], directory: URL,
                    outputLimit: Int = 2 * 1024 * 1024, timeout: TimeInterval = 30,
                    monitor: () throws -> Void = {}) throws -> Data {
        try Task.checkCancellation()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw AppearanceError.invalid("Could not prepare archive output.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        try process.run()
        try? pipe.fileHandleForWriting.close()
        var output = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        do {
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw AppearanceError.invalid("Archive tool timed out.") }
                try monitor()
                // Bound each read and each pass, including when a producer never stops writing.
                for _ in 0..<16 {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        guard count <= outputLimit - output.count else { throw AppearanceError.invalid("Archive tool exceeded its output limit.") }
                        output.append(contentsOf: buffer.prefix(count))
                    } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else if errno != EINTR { throw AppearanceError.invalid("Could not read archive tool output.") }
                }
                if !process.isRunning {
                    // The child has closed its writer. Drain the bounded remainder without waiting for EOF
                    // from an unrelated inherited descriptor.
                    while true {
                        try Task.checkCancellation()
                        guard ContinuousClock.now < deadline else { throw AppearanceError.invalid("Archive tool timed out.") }
                        let count = Darwin.read(descriptor, &buffer, buffer.count)
                        if count > 0 {
                            guard count <= outputLimit - output.count else { throw AppearanceError.invalid("Archive tool exceeded its output limit.") }
                            output.append(contentsOf: buffer.prefix(count))
                        } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { break }
                        else if errno != EINTR { throw AppearanceError.invalid("Could not read archive tool output.") }
                    }
                    try monitor() // Also inspect tools which finish between polling intervals.
                    guard process.terminationStatus == 0 else {
                        throw AppearanceError.invalid("Archive tool failed. Select the already-extracted application instead.")
                    }
                    return output
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        } catch {
            try stop(process)
            throw error
        }
    }

    private static func stop(_ process: Process) throws {
        guard process.isRunning else { return }
        process.terminate()
        let grace = ContinuousClock.now.advanced(by: .milliseconds(200))
        while process.isRunning && ContinuousClock.now < grace { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { throw AppearanceError.invalid("The archive tool could not be stopped.") }
    }
}
