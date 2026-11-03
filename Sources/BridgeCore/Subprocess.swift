import Foundation
import Darwin

public enum Subprocess {
    public struct Result { public let status: Int32; public let stdout: Data; public let stderr: Data }
    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 6) throws -> Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inputbridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outURL = folder.appendingPathComponent("stdout")
        let errURL = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw BridgeError("Timed out after \(timeout)s: \(executable.lastPathComponent)")
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL))
    }

    public static func decoded<T: Decodable>(_ type: T.Type, executable: URL, args: [String]) throws -> T {
        let result = try run(executable, args)
        guard result.status == 0 else { throw BridgeError(String(decoding: result.stderr, as: UTF8.self)) }
        return try JSONDecoder().decode(type, from: result.stdout)
    }
}
