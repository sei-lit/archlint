import Foundation

/// 検査する木（working tree、git の index、HEAD）。パスはリポジトリのルートからの相対パス
protocol SourceTree {
    /// 通常のファイルのパスと、内容を識別する値（blob の SHA など）
    var files: [String: String] { get }
    func read(_ paths: [String]) throws -> [String: Data]
}

extension SourceTree {
    func read(_ path: String) throws -> Data {
        guard let data = try read([path])[path] else { throw ToolError("\(path) を読めない") }
        return data
    }

    func text(_ path: String) throws -> String {
        String(decoding: try read(path), as: UTF8.self)
    }

    func files(under directory: String) -> [String] {
        files.keys.filter { Paths.relative($0, to: directory) != nil }.sorted()
    }
}

struct WorkingTree: SourceTree {
    let root: String
    let files: [String: String]

    /// `directory`（ルートからの相対）の下の通常のファイル。symlink はたどらない
    init(root: String, directory: String) {
        self.root = root
        var files: [String: String] = [:]
        let base = URL(fileURLWithPath: Paths.join(root, directory))
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        if let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                let full = url.standardizedFileURL.path
                let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
                guard let relative = Paths.relative(full, to: rootPath) else { continue }
                if relative.hasPrefix(".git/") || relative.contains("/.build/") { continue }
                files[relative] = "worktree:\(relative)"
            }
        }
        self.files = files
    }

    func read(_ paths: [String]) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in paths {
            result[path] = try Data(contentsOf: URL(fileURLWithPath: Paths.join(root, path)))
        }
        return result
    }
}

/// git の index か commit の木。通常のファイル（100644 / 100755）だけを持つ。
/// symlink と submodule は内容を持たず、書き出すと working tree の内容を読んでしまうので除く
struct GitTree: SourceTree {
    let root: String
    let files: [String: String]

    static let regularModes: Set<String> = ["100644", "100755"]

    static func index(root: String) throws -> GitTree {
        let output = try Shell.git(["ls-files", "--stage", "-z"], cwd: root)
        var files: [String: String] = [:]
        for entry in output.split(separator: 0) {
            // <mode> <sha> <stage>\t<path>
            guard let tab = entry.firstIndex(of: 9) else { continue }
            let meta = String(decoding: entry[entry.startIndex..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: entry[(tab + 1)...], as: UTF8.self)
            guard meta.count == 3, regularModes.contains(String(meta[0])), meta[2] == "0" else { continue }
            files[path] = String(meta[1])
        }
        return GitTree(root: root, files: files)
    }

    /// HEAD が無い（最初のコミット）ときは空の木
    static func head(root: String) throws -> GitTree {
        let verify = try Shell.run("git", ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], cwd: root)
        guard verify.status == 0 else { return GitTree(root: root, files: [:]) }
        let output = try Shell.git(["ls-tree", "-r", "-z", "--full-tree", "HEAD"], cwd: root)
        var files: [String: String] = [:]
        for entry in output.split(separator: 0) {
            // <mode> <type> <sha>\t<path>
            guard let tab = entry.firstIndex(of: 9) else { continue }
            let meta = String(decoding: entry[entry.startIndex..<tab], as: UTF8.self).split(separator: " ")
            let path = String(decoding: entry[(tab + 1)...], as: UTF8.self)
            guard meta.count == 3, regularModes.contains(String(meta[0])), meta[1] == "blob" else { continue }
            files[path] = String(meta[2])
        }
        return GitTree(root: root, files: files)
    }

    func read(_ paths: [String]) throws -> [String: Data] {
        let shas = paths.compactMap { files[$0] }
        guard shas.count == paths.count else {
            throw ToolError("git の木に無いファイル: \(paths.filter { files[$0] == nil }.joined(separator: ", "))")
        }
        let blobs = try Self.readBlobs(Array(Set(shas)), root: root)
        var result: [String: Data] = [:]
        for path in paths { result[path] = blobs[files[path]!] }
        return result
    }

    /// `git cat-file --batch` で blob をまとめて読む
    static func readBlobs(_ shas: [String], root: String) throws -> [String: Data] {
        guard !shas.isEmpty else { return [:] }
        let input = Data(shas.map { "\($0)\n" }.joined().utf8)
        let output = try Shell.git(["cat-file", "--batch"], cwd: root, input: input)
        var result: [String: Data] = [:]
        var cursor = output.startIndex
        while cursor < output.endIndex {
            guard let newline = output[cursor...].firstIndex(of: 10) else { break }
            let header = String(decoding: output[cursor..<newline], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let size = Int(header[2]) else {
                throw ToolError("git cat-file の出力を読めない: \(header.joined(separator: " "))")
            }
            let start = newline + 1
            let end = start + size
            guard end <= output.endIndex else { throw ToolError("git cat-file の出力が途中で切れている") }
            result[String(header[0])] = Data(output[start..<end])
            cursor = end + 1
        }
        guard result.count == shas.count else { throw ToolError("git cat-file で読めない blob がある") }
        return result
    }

    /// 指定したファイルを一時ディレクトリに書き出す（ast-grep に渡すため）
    func export(_ paths: [String], to directory: String) throws {
        let contents = try read(paths)
        for (path, data) in contents {
            let url = URL(fileURLWithPath: Paths.join(directory, path))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }
}
