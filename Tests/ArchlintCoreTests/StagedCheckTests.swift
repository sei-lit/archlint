@testable import ArchlintCore
import Foundation
import Testing

/// 一時ディレクトリに git リポジトリを作り、`check --staged` を実際の index と HEAD で確かめる
private final class Repository {
    let root: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archlint-test-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "test")
        try write("app/archlint.yml", """
        version: 1
        sources: [Sources/**]
        rules: rules
        baseline: baseline.json
        """)
        try write("app/rules/closure-view.yml", """
        id: closure-view
        message: クロージャを持つ View は AutoEquatable にする
        select:
          type:
            inherits: View
            has: { member: { stored: true, type: { function: true } } }
        require:
          attribute: AutoEquatable
        """)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func write(_ path: String, _ content: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> Data {
        try Shell.git(arguments, cwd: root)
    }

    func stageAll() throws { try git("add", "-A") }

    func record() throws {
        try stageAll()
        try git("commit", "-q", "-m", "snapshot")
    }

    func check() throws -> Commands.CheckResult {
        var options = Options()
        options.staged = true
        options.config = "app/archlint.yml"
        options.workingDirectory = root
        return try Commands.runCheck(options)
    }
}

private let plainView = "struct A: View { let title: String; var body: some View { EmptyView() } }"
private let closureView = "struct A: View { let onTap: Handler; var body: some View { EmptyView() } }"

@Suite(.serialized) struct StagedCheckTests {
    @Test func violationAlreadyInHeadDoesNotBlockAnUnrelatedCommit() throws {
        let repo = try Repository()
        try repo.write("app/Sources/Handler.swift", "typealias Handler = () -> Void")
        try repo.write("app/Sources/A.swift", closureView)
        try repo.record()
        try repo.write("app/Sources/Other.swift", "struct Other {}")
        try repo.stageAll()
        let result = try repo.check()
        #expect(result.exitCode == .ok)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func changingATypealiasInAnotherFileBlocksAndPointsAtTheUnchangedView() throws {
        let repo = try Repository()
        try repo.write("app/Sources/Handler.swift", "typealias Handler = String")
        try repo.write("app/Sources/A.swift", closureView)
        try repo.record()
        try repo.write("app/Sources/Handler.swift", "typealias Handler = () -> Void")
        try repo.stageAll()
        let result = try repo.check()
        #expect(result.exitCode == .violations)
        #expect(result.diagnostics.map(\.file) == ["app/Sources/A.swift"])
    }

    @Test func unstagedEditsAreNotChecked() throws {
        let repo = try Repository()
        try repo.write("app/Sources/Handler.swift", "typealias Handler = () -> Void")
        try repo.write("app/Sources/A.swift", plainView)
        try repo.record()
        try repo.write("app/Sources/B.swift", "struct B {}")
        try repo.stageAll()
        try repo.write("app/Sources/A.swift", closureView)
        #expect(try repo.check().exitCode == .ok)
    }

    @Test func baselinedViolationPassesAndFixingItRequiresPruning() throws {
        let repo = try Repository()
        try repo.write("app/Sources/Handler.swift", "typealias Handler = () -> Void")
        try repo.write("app/Sources/A.swift", closureView)
        try repo.write("app/baseline.json", """
        {"entries": {"closure-view | Sources/A.swift | type A": 1}, "version": 1}
        """)
        try repo.stageAll()
        #expect(try repo.check().exitCode == .ok)
        try repo.record()

        try repo.write("app/Sources/A.swift", plainView)
        try repo.stageAll()
        let result = try repo.check()
        #expect(result.exitCode == .violations)
        #expect(result.stale.count == 1)
    }

    @Test func syntaxErrorInAStagedFileIsAToolError() throws {
        let repo = try Repository()
        try repo.write("app/Sources/A.swift", "struct A {\n  var x: = 1\n}")
        try repo.stageAll()
        #expect(throws: ToolError.self) { try repo.check() }
    }

    @Test func syntaxErrorInAnUnchangedFileIsAlsoAToolError() throws {
        let repo = try Repository()
        try repo.write("app/Sources/A.swift", "struct A {\n  var x: = 1\n}")
        try repo.record()
        try repo.write("app/Sources/B.swift", "struct B {}")
        try repo.stageAll()
        #expect(throws: ToolError.self) { try repo.check() }
    }

    @Test func configMustBeInTheIndex() throws {
        let repo = try Repository()
        try repo.write("app/Sources/A.swift", plainView)
        #expect(throws: ToolError.self) { try repo.check() }
    }

    @Test func rulesAreReadFromTheIndexNotTheWorkingTree() throws {
        let repo = try Repository()
        try repo.write("app/Sources/Handler.swift", "typealias Handler = () -> Void")
        try repo.write("app/Sources/A.swift", plainView)
        try repo.record()
        try repo.write("app/Sources/A.swift", closureView)
        try repo.stageAll()
        // stage していないルールの変更（ルールを消す）は効かない
        try FileManager.default.removeItem(atPath: repo.root + "/app/rules/closure-view.yml")
        #expect(try repo.check().exitCode == .violations)
    }
}

@Suite(.serialized) struct RuleTestCommandTests {
    @Test func multiFileCasesAndFailuresAreReported() throws {
        let repo = try Repository()
        try repo.write("app/archlint.yml", """
        version: 1
        sources: [Sources/**]
        rules: rules
        tests: rule-tests
        """)
        try repo.write("app/rule-tests/closure-view-test.yml", """
        id: closure-view
        valid:
          - 'struct A: View { let title: String; var body: some View { EmptyView() } }'
        invalid:
          - files:
              Handler.swift: typealias Handler = () -> Void
              A.swift: 'struct A: View { let onTap: Handler; var body: some View { EmptyView() } }'
        """)
        var options = Options()
        options.config = "app/archlint.yml"
        options.workingDirectory = repo.root
        #expect(try Commands.test(options) == .ok)

        try repo.write("app/rule-tests/closure-view-test.yml", """
        id: closure-view
        invalid:
          - 'struct A: View { let title: String; var body: some View { EmptyView() } }'
        """)
        #expect(try Commands.test(options) == .violations)
    }
}

/// ast-grep が無い環境（Linux の CI など）では飛ばす
private let astGrepPath = ProcessInfo.processInfo.environment["ARCHLINT_TEST_AST_GREP"]

@Suite(.serialized, .enabled(if: astGrepPath != nil)) struct AstGrepTests {
    @Test func stagedSwiftFilesAreScannedWithIndexContent() throws {
        let repo = try Repository()
        try repo.write("app/archlint.yml", """
        version: 1
        sources: [Sources/**]
        rules: rules
        astGrep: { config: sgconfig.yml }
        """)
        try repo.write("app/sgconfig.yml", "ruleDirs: [ast-grep-rules]\n")
        try repo.write("app/ast-grep-rules/no-print.yml", """
        id: no-print
        language: swift
        severity: error
        message: print を使わない
        rule: { pattern: print($A) }
        """)
        try repo.write("app/Sources/A.swift", "func f() { print(1) }")
        try repo.write("app/Sources/B.swift", "func g() {}")
        try repo.stageAll()
        try repo.write("app/Sources/B.swift", "func g() { print(2) }")
        var options = Options()
        options.staged = true
        options.config = "app/archlint.yml"
        options.workingDirectory = repo.root
        options.astGrep = astGrepPath
        let result = try Commands.runCheck(options)
        #expect(result.diagnostics.map { "\($0.file):\($0.line):\($0.rule)" } == ["app/Sources/A.swift:1:no-print"])
        #expect(result.exitCode == .violations)
    }
}
