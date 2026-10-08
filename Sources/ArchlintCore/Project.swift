import Foundation
import Yams

/// `archlint.yml`。パスはこのファイルのあるディレクトリからの相対パス
public struct Config {
    static let version = 1
    static let keys: Set<String> = ["version", "sources", "ignores", "module", "rules", "tests", "baseline", "astGrep"]

    let sources: [Glob]
    let ignores: [Glob]
    /// 名前付きグループ `module` を持つ正規表現。モジュールが違えば同名の型を別のものとして扱う
    let module: NSRegularExpression?
    let rules: String
    let tests: String?
    let baseline: String?
    let astGrepConfig: String?

    static func parse(_ text: String, source: String) throws -> Config {
        guard let root = try Yams.load(yaml: text) as? [String: Any] else {
            throw ToolError("\(source): 設定は YAML の mapping で書く")
        }
        do {
            try checkKeys(root, allowed: keys, at: source)
        } catch let error as ConfigError {
            throw ToolError(error.description)
        }
        guard let version = root["version"] as? Int, version == Self.version else {
            throw ToolError("\(source): version: \(Self.version) を書く（この archlint が読める設定の形式）")
        }
        guard let rules = root["rules"] as? String else { throw ToolError("\(source): rules（ルールのディレクトリ）が無い") }
        guard root["sources"] != nil else { throw ToolError("\(source): sources（事実を集めるファイルの glob）が無い") }
        var module: NSRegularExpression?
        if let pattern = root["module"] {
            guard let pattern = pattern as? String, let regex = try? NSRegularExpression(pattern: pattern),
                  pattern.contains("(?<module>") else {
                throw ToolError("\(source): module は名前付きグループ (?<module>...) を持つ正規表現で書く")
            }
            module = regex
        }
        var astGrepConfig: String?
        if let astGrep = root["astGrep"] {
            guard let map = astGrep as? [String: Any], let config = map["config"] as? String, map.count == 1 else {
                throw ToolError("\(source): astGrep には config（sgconfig.yml のパス）だけを書く")
            }
            astGrepConfig = config
        }
        do {
            return Config(
                sources: try globs(root["sources"], at: "\(source) sources"),
                ignores: try globs(root["ignores"], at: "\(source) ignores"),
                module: module,
                rules: rules,
                tests: root["tests"] as? String,
                baseline: root["baseline"] as? String,
                astGrepConfig: astGrepConfig
            )
        } catch let error as ConfigError {
            throw ToolError(error.description)
        }
    }

    func isSource(_ path: String) -> Bool {
        path.hasSuffix(".swift") && sources.contains { $0.matches(path) } && !ignores.contains { $0.matches(path) }
    }

    func module(of path: String) -> String {
        guard let module else { return "" }
        let range = NSRange(path.startIndex..., in: path)
        guard let match = module.firstMatch(in: path, range: range),
              let captured = Range(match.range(withName: "module"), in: path) else { return "" }
        return String(path[captured])
    }
}

/// 設定・ルール・baseline を同じ木から読む（--staged では index から。コミットされる内容とルールを揃えるため）
struct Project {
    let tree: SourceTree
    /// 設定ファイルのあるディレクトリ（ルートからの相対）
    let directory: String
    let config: Config
    let rules: [Rule]

    static func load(tree: SourceTree, configPath: String) throws -> Project {
        guard tree.files[configPath] != nil else {
            throw ToolError("設定ファイルが無い（--staged では git add が要る）: \(configPath)")
        }
        let directory = Paths.directory(of: configPath)
        let config = try Config.parse(try tree.text(configPath), source: configPath)
        let rulesDirectory = Paths.join(directory, config.rules)
        let ruleFiles = tree.files(under: rulesDirectory).filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        var rules: [Rule] = []
        var ids: Set<String> = []
        for path in ruleFiles {
            do {
                let rule = try Rule.parse(yaml: try tree.text(path), source: path)
                guard ids.insert(rule.id).inserted else { throw ToolError("\(path): id \(rule.id) が重複している") }
                rules.append(rule)
            } catch let error as ConfigError {
                throw ToolError(error.description)
            } catch let error as YamlError {
                throw ToolError("\(path): YAML を読めない: \(error)")
            }
        }
        return Project(tree: tree, directory: directory, config: config, rules: rules)
    }

    /// 設定ディレクトリからの相対パスで、事実を集めるファイル
    var sourceFiles: [String] { sourceFiles(in: tree) }

    func sourceFiles(in tree: SourceTree) -> [String] {
        tree.files(under: directory).compactMap { path in
            Paths.relative(path, to: directory).flatMap { config.isSource($0) ? $0 : nil }
        }
    }

    var baselinePath: String? { config.baseline.map { Paths.join(directory, $0) } }

    func loadBaseline() throws -> Baseline {
        guard let path = baselinePath, tree.files[path] != nil else { return Baseline() }
        return try Baseline.parse(try tree.read(path), source: path)
    }
}

/// 事実の抽出は 1 ファイルずつ独立なので、内容が同じファイルは HEAD と index で使い回す
final class FactCache: @unchecked Sendable {
    private var cache: [String: FileFacts] = [:]
    private let lock = NSLock()

    func facts(tree: SourceTree, directory: String, config: Config, paths: [String]) throws -> [FileFacts] {
        var missing: [String] = []
        var result: [String: FileFacts] = [:]
        lock.lock()
        for path in paths {
            if let cached = cache[cacheKey(tree, directory, path)] { result[path] = cached } else { missing.append(path) }
        }
        lock.unlock()
        let contents = try tree.read(missing.map { Paths.join(directory, $0) })
        let jobs = missing.map { path in
            (path: path, source: String(decoding: contents[Paths.join(directory, path)] ?? Data(), as: UTF8.self),
             module: config.module(of: path))
        }
        let slots = ResultSlots(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            slots.set(index, FactExtractor.extract(source: job.source, path: job.path, module: job.module))
        }
        let extracted = slots.values
        lock.lock()
        for (index, path) in missing.enumerated() {
            let facts = extracted[index]!
            cache[cacheKey(tree, directory, path)] = facts
            result[path] = facts
        }
        lock.unlock()
        return paths.map { result[$0]! }
    }

    private func cacheKey(_ tree: SourceTree, _ directory: String, _ path: String) -> String {
        "\(path)\u{0}\(tree.files[Paths.join(directory, path)] ?? "")"
    }
}

/// 並列に抽出した結果を添字ごとに受け取る
private final class ResultSlots: @unchecked Sendable {
    private var storage: [FileFacts?]
    private let lock = NSLock()

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ value: FileFacts) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    var values: [FileFacts?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
