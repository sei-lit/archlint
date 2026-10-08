import Foundation
import Yams

public enum ExitCode: Int32 {
    case ok = 0
    case violations = 1
    case toolError = 2
}

public struct Options {
    public var config: String = "archlint.yml"
    public var staged = false
    public var astGrep: String?
    public var astGrepVersion: String?
    public var prune = false
    public var paths: [String] = []
    public var workingDirectory = FileManager.default.currentDirectoryPath

    public init() {}
}

public enum Commands {
    public static let version = "0.2.0"

    static func repositoryRoot(_ options: Options) throws -> String {
        let output = try Shell.git(["rev-parse", "--show-toplevel"], cwd: options.workingDirectory)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 設定ファイルの、リポジトリのルートからの相対パス
    static func configPath(_ options: Options, root: String) throws -> String {
        let option = options.config
        let cwd = options.workingDirectory
        let absolute = Paths.normalize(option.hasPrefix("/") ? option : Paths.join(cwd, option))
        let rootPath = Paths.normalize(URL(fileURLWithPath: root).resolvingSymlinksInPath().path)
        let resolved = Paths.normalize(URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path)
        guard let relative = Paths.relative(resolved, to: rootPath) ?? Paths.relative(absolute, to: Paths.normalize(root)) else {
            throw ToolError("設定ファイルがリポジトリの外にある: \(option)")
        }
        return relative
    }

    // MARK: - check

    public struct CheckResult {
        public let diagnostics: [Diagnostic]
        public let stale: [String]
        public let baselined: Int
        public let suppressed: Int

        public var exitCode: ExitCode {
            diagnostics.contains { $0.severity == .error } || !stale.isEmpty ? .violations : .ok
        }
    }

    public static func check(_ options: Options) throws -> ExitCode {
        let result = try runCheck(options)
        Report.print(result.diagnostics)
        for entry in result.stale {
            Report.line("error[baseline]: \(entry)")
        }
        if !result.stale.isEmpty {
            Report.line("  note: archlint baseline --prune --config \(options.config) で baseline を減らし、一緒にコミットする")
        }
        let errors = result.diagnostics.filter { $0.severity == .error }.count + result.stale.count
        Report.summary(errors: errors, warnings: result.diagnostics.count - (errors - result.stale.count),
                       baselined: result.baselined, suppressed: result.suppressed)
        return result.exitCode
    }

    public static func runCheck(_ options: Options) throws -> CheckResult {
        let root = try repositoryRoot(options)
        let configPath = try configPath(options, root: root)
        let tree: SourceTree = options.staged ? try GitTree.index(root: root) : WorkingTree(root: root, directory: Paths.directory(of: configPath))
        let project = try Project.load(tree: tree, configPath: configPath)
        let cache = FactCache()

        let files = try cache.facts(tree: tree, directory: project.directory, config: project.config, paths: project.sourceFiles)
        var head: [Diagnostic]?
        var changed: Set<String> = []
        if options.staged {
            let headTree = try GitTree.head(root: root)
            // HEAD のコードも index のルールで判定する。ルールの変更で既存のコードが違反になっても、
            // それはこのコミットで増えた違反ではないので止めない
            let headFiles = try cache.facts(
                tree: headTree, directory: project.directory, config: project.config,
                paths: project.sourceFiles(in: headTree)
            )
            head = Evaluator.evaluate(project.rules, on: FactSet(files: headFiles)).diagnostics
            changed = Set(project.sourceFiles.filter {
                let path = Paths.join(project.directory, $0)
                return tree.files[path] != headTree.files[path]
            })
        }
        try failOnSyntaxErrors(files, changed: options.staged ? changed : nil, directory: project.directory)

        let evaluation = Evaluator.evaluate(project.rules, on: FactSet(files: files))
        let baseline = try project.loadBaseline()
        let new = NewDiagnostics.select(evaluation.diagnostics, head: head, baseline: baseline)
        let stale = baseline.stale(against: evaluation.diagnostics)

        var astGrepDiagnostics: [Diagnostic] = []
        if let astGrepConfig = project.config.astGrepConfig {
            let astGrep = try AstGrep.resolve(options.astGrep, requiredVersion: options.astGrepVersion)
            astGrepDiagnostics = try runAstGrep(
                astGrep, configPath: Paths.join(project.directory, astGrepConfig),
                tree: tree, staged: options.staged, root: root
            )
        }

        let shown = new.map { located($0, directory: project.directory) } + astGrepDiagnostics
        return CheckResult(
            diagnostics: shown.sorted { ($0.file, $0.line, $0.rule) < ($1.file, $1.line, $1.rule) },
            stale: stale.map { "\(project.baselinePath ?? "baseline"): 違反が \($0.expected) 件から \($0.actual) 件に減った: \($0.key)" },
            baselined: evaluation.diagnostics.count - new.count,
            suppressed: evaluation.suppressed.values.reduce(0, +)
        )
    }

    static func located(_ diagnostic: Diagnostic, directory: String) -> Diagnostic {
        Diagnostic(
            rule: diagnostic.rule, severity: diagnostic.severity, message: diagnostic.message, note: diagnostic.note,
            file: Paths.join(directory, diagnostic.file), line: diagnostic.line, key: diagnostic.key
        )
    }

    /// 構文エラーのあるファイルの事実は欠けるので、違反を見落とさないよう検査を通さない。
    /// --staged では、このコミットで変えていないファイルの構文エラーでは止めない（HEAD で既に壊れていて、このコミットの責任ではないため）
    static func failOnSyntaxErrors(_ files: [FileFacts], changed: Set<String>?, directory: String) throws {
        let broken = files.filter { !$0.syntaxErrors.isEmpty }
        let blocking = broken.filter { changed?.contains($0.path) ?? true }
        for file in broken where !blocking.contains(where: { $0.path == file.path }) {
            FileHandle.standardError.write(Data("archlint: warning: 構文エラーがあり、事実が欠けている可能性がある: \(Paths.join(directory, file.path)):\(file.syntaxErrors[0])\n".utf8))
        }
        guard blocking.isEmpty else {
            let list = blocking.map { "  \(Paths.join(directory, $0.path)):\($0.syntaxErrors[0])" }.joined(separator: "\n")
            throw ToolError("構文エラーがあるため検査できない:\n\(list)")
        }
    }

    static func runAstGrep(_ astGrep: AstGrep, configPath: String, tree: SourceTree, staged: Bool, root: String) throws -> [Diagnostic] {
        let configDirectory = Paths.directory(of: configPath)
        guard tree.files[configPath] != nil else { throw ToolError("ast-grep の設定が無い: \(configPath)") }
        guard staged, let gitTree = tree as? GitTree else {
            let diagnostics = try astGrep.scan(config: Paths.join(root, configPath), targets: [], cwd: Paths.join(root, configDirectory))
            return diagnostics.map { relocate($0, from: root) }
        }
        // ast-grep のルールは 1 ファイルで完結するので、stage したファイルだけを見る
        let output = try Shell.git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], cwd: root)
        let staged = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            .filter { Paths.relative($0, to: configDirectory) != nil && gitTree.files[$0] != nil }
        guard !staged.isEmpty else { return [] }
        let ruleFiles = gitTree.files(under: configDirectory).filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("archlint-\(UUID().uuidString)").path
        defer {
            do {
                try FileManager.default.removeItem(atPath: temporary)
            } catch {
                FileHandle.standardError.write(Data("archlint: warning: 一時ディレクトリを消せない: \(temporary)\n".utf8))
            }
        }
        try gitTree.export(Array(Set(staged + ruleFiles)), to: temporary)
        let diagnostics = try astGrep.scan(
            config: Paths.join(temporary, configPath),
            targets: staged.map { Paths.join(temporary, $0) },
            cwd: Paths.join(temporary, configDirectory)
        )
        let resolvedTemporary = Paths.normalize(URL(fileURLWithPath: temporary).resolvingSymlinksInPath().path)
        return diagnostics.map { diagnostic in
            let file = Paths.relative(diagnostic.file, to: Paths.normalize(temporary))
                ?? Paths.relative(Paths.normalize(URL(fileURLWithPath: diagnostic.file).resolvingSymlinksInPath().path), to: resolvedTemporary)
                ?? diagnostic.file
            return Diagnostic(rule: diagnostic.rule, severity: diagnostic.severity, message: diagnostic.message,
                              note: diagnostic.note, file: file, line: diagnostic.line, key: diagnostic.key)
        }
    }

    static func relocate(_ diagnostic: Diagnostic, from root: String) -> Diagnostic {
        let rootPath = Paths.normalize(URL(fileURLWithPath: root).resolvingSymlinksInPath().path)
        let resolved = Paths.normalize(URL(fileURLWithPath: diagnostic.file).resolvingSymlinksInPath().path)
        let file = Paths.relative(resolved, to: rootPath) ?? Paths.relative(diagnostic.file, to: root) ?? diagnostic.file
        return Diagnostic(rule: diagnostic.rule, severity: diagnostic.severity, message: diagnostic.message,
                          note: diagnostic.note, file: file, line: diagnostic.line, key: diagnostic.key)
    }

    // MARK: - baseline

    public static func baseline(_ options: Options) throws -> ExitCode {
        let root = try repositoryRoot(options)
        let configPath = try configPath(options, root: root)
        let tree = WorkingTree(root: root, directory: Paths.directory(of: configPath))
        let project = try Project.load(tree: tree, configPath: configPath)
        guard let baselinePath = project.baselinePath else { throw ToolError("設定に baseline のパスが無い") }
        let files = try FactCache().facts(tree: tree, directory: project.directory, config: project.config, paths: project.sourceFiles)
        try failOnSyntaxErrors(files, changed: nil, directory: project.directory)
        let diagnostics = Evaluator.evaluate(project.rules, on: FactSet(files: files)).diagnostics
        let current = try project.loadBaseline()
        let updated = options.prune ? current.pruned(against: diagnostics) : Baseline(diagnostics)
        try updated.serialized().write(to: URL(fileURLWithPath: Paths.join(root, baselinePath)))
        let total = updated.counts.values.reduce(0, +)
        Report.line("archlint: baseline に \(total) 件（\(updated.counts.count) キー）を書いた: \(baselinePath)")
        return .ok
    }

    // MARK: - facts

    public static func facts(_ options: Options) throws -> ExitCode {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var all: [FileFacts] = []
        for path in options.paths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            all.append(FactExtractor.extract(source: source, path: path, module: ""))
        }
        FileHandle.standardOutput.write(try encoder.encode(all))
        FileHandle.standardOutput.write(Data("\n".utf8))
        return .ok
    }

    // MARK: - test

    public static func test(_ options: Options) throws -> ExitCode {
        let root = try repositoryRoot(options)
        let configPath = try configPath(options, root: root)
        let tree = WorkingTree(root: root, directory: Paths.directory(of: configPath))
        let project = try Project.load(tree: tree, configPath: configPath)
        var passed = true
        if let tests = project.config.tests {
            let directory = Paths.join(project.directory, tests)
            let files = tree.files(under: directory).filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            passed = try RuleTests.run(files: files, tree: tree, rules: project.rules) && passed
        }
        if let astGrepConfig = project.config.astGrepConfig {
            let astGrep = try AstGrep.resolve(options.astGrep, requiredVersion: options.astGrepVersion)
            let config = Paths.join(project.directory, astGrepConfig)
            passed = try astGrep.test(config: Paths.join(root, config), cwd: Paths.join(root, Paths.directory(of: config))) && passed
        }
        return passed ? .ok : .violations
    }

    // MARK: - doctor

    public static func doctor(_ options: Options) throws -> ExitCode {
        Report.line("archlint \(version)（swift-syntax 604.0.0）")
        let git = try Shell.run("git", ["--version"])
        Report.line(String(decoding: git.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let root = try repositoryRoot(options)
        let configPath = try configPath(options, root: root)
        let tree = WorkingTree(root: root, directory: Paths.directory(of: configPath))
        let project = try Project.load(tree: tree, configPath: configPath)
        Report.line("設定: \(configPath)（ルール \(project.rules.count) 件、対象 \(project.sourceFiles.count) ファイル）")
        if project.config.astGrepConfig != nil {
            let astGrep = try AstGrep.resolve(options.astGrep, requiredVersion: options.astGrepVersion)
            Report.line("ast-grep: \(try astGrep.version())（\(astGrep.executable)）")
        }
        return .ok
    }
}

enum Report {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func print(_ diagnostics: [Diagnostic]) {
        let sorted = diagnostics.sorted { ($0.file, $0.line, $0.rule) < ($1.file, $1.line, $1.rule) }
        for diagnostic in sorted {
            line("\(diagnostic.file):\(diagnostic.line): \(diagnostic.severity.rawValue)[\(diagnostic.rule)]: \(diagnostic.message)")
            if let note = diagnostic.note?.trimmingCharacters(in: .newlines), !note.isEmpty {
                line("  note: " + note.replacingOccurrences(of: "\n", with: "\n        "))
            }
        }
    }

    static func summary(errors: Int, warnings: Int, baselined: Int, suppressed: Int) {
        let text = "archlint: error \(errors) 件、warning \(warnings) 件（baseline \(baselined) 件、archlint-ignore \(suppressed) 件は除外）\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

enum RuleTests {
    struct Case {
        let files: [String: String]
    }

    static func run(files: [String], tree: SourceTree, rules: [Rule]) throws -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        var failures: [String] = []
        var total = 0
        for path in files {
            guard let root = try Yams.load(yaml: try tree.text(path)) as? [String: Any] else {
                throw ToolError("\(path): テストは YAML の mapping で書く")
            }
            do {
                try checkKeys(root, allowed: ["id", "valid", "invalid"], at: path)
            } catch let error as ConfigError {
                throw ToolError(error.description)
            }
            guard let id = root["id"] as? String, let rule = byID[id] else {
                throw ToolError("\(path): id のルールが無い")
            }
            for (expectViolation, key) in [(false, "valid"), (true, "invalid")] {
                for (index, raw) in (root[key] as? [Any] ?? []).enumerated() {
                    total += 1
                    let testCase = try parseCase(raw, at: "\(path) \(key)[\(index)]")
                    let facts = testCase.files.sorted { $0.key < $1.key }.map {
                        FactExtractor.extract(source: $0.value, path: $0.key, module: "")
                    }
                    if let broken = facts.first(where: { !$0.syntaxErrors.isEmpty }) {
                        failures.append("\(path) \(key)[\(index)]: 構文エラー \(broken.path):\(broken.syntaxErrors[0])")
                        continue
                    }
                    let found = Evaluator.evaluate([rule], on: FactSet(files: facts), applyFileFilters: false).diagnostics
                    if found.isEmpty == expectViolation {
                        let detail = expectViolation ? "違反を検出しなかった" : "違反を検出した（\(found.map { "\($0.file):\($0.line)" }.joined(separator: ", "))）"
                        failures.append("\(path) \(key)[\(index)]: \(detail)")
                    }
                }
            }
        }
        for failure in failures { Report.line("FAIL \(failure)") }
        Report.line("archlint test: \(total - failures.count)/\(total) 件が通った")
        return failures.isEmpty
    }

    /// 文字列なら Test.swift の 1 ファイル、`files:` ならファイル名と中身の組
    static func parseCase(_ raw: Any, at path: String) throws -> Case {
        if let source = raw as? String { return Case(files: ["Test.swift": source]) }
        guard let map = raw as? [String: Any], map.count == 1, let files = map["files"] as? [String: Any], !files.isEmpty else {
            throw ToolError("\(path): コードの文字列か、files: { ファイル名: コード } で書く")
        }
        var result: [String: String] = [:]
        for (name, source) in files {
            guard let source = source as? String else { throw ToolError("\(path): \(name) の中身は文字列で書く") }
            result[name] = source
        }
        return Case(files: result)
    }
}
