import Foundation

/// 環境・設定・使い方の誤り（終了コード 2）
public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    /// 出力は一時ファイルで受ける。パイプだと大きな出力で子プロセスが止まるため
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil, input: Data? = nil) throws -> ProcessResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("archlint-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("out")
        let errURL = directory.appendingPathComponent("err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)

        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = out
        process.standardError = err
        let pipe = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : pipe
        do {
            try process.run()
        } catch {
            throw ToolError("\(executable) を実行できない: \(error.localizedDescription)")
        }
        if let input {
            pipe.fileHandleForWriting.write(input)
            try? pipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        try out.close()
        try err.close()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: outURL),
            stderr: try Data(contentsOf: errURL)
        )
    }

    static func git(_ arguments: [String], cwd: String, input: Data? = nil) throws -> Data {
        let result = try run("git", arguments, cwd: cwd, input: input)
        guard result.status == 0 else {
            throw ToolError("git \(arguments.joined(separator: " ")) が失敗した: \(result.stderrText)")
        }
        return result.stdout
    }
}

enum Paths {
    static func join(_ base: String, _ path: String) -> String {
        if base.isEmpty || base == "." { return path }
        if path.isEmpty || path == "." { return base }
        return base.hasSuffix("/") ? base + path : "\(base)/\(path)"
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// `base` の下にあれば base からの相対パス
    static func relative(_ path: String, to base: String) -> String? {
        if base.isEmpty { return path }
        if path == base { return "" }
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
    }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." {
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }
}
