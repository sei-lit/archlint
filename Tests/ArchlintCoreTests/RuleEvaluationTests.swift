@testable import ArchlintCore
import Testing

private func violations(_ rule: String, _ files: [String: String]) throws -> [Diagnostic] {
    let parsed = try Rule.parse(yaml: rule, source: "test")
    let facts = files.sorted { $0.key < $1.key }.map { FactExtractor.extract(source: $0.value, path: $0.key, module: "") }
    return Evaluator.evaluate([parsed], on: FactSet(files: facts), applyFileFilters: false).diagnostics
}

private func violations(_ rule: String, _ source: String) throws -> [Diagnostic] {
    try violations(rule, ["Test.swift": source])
}

private let viewAsStruct = """
id: view-as-struct
message: m
select:
  member:
    kind: [func, var]
    returns: { opaque: View }
    preview: false
    not:
      any:
        - name: [body, equatableBody, makeBody]
        - declaredIn: extension
          owner: View
"""

private let closureView = """
id: closure-view
message: m
select:
  type:
    kind: struct
    inherits: View
    has: { member: { stored: true, static: false, type: { function: true } } }
    not:
      has: { member: { attribute: [StateObject, Binding] } }
require:
  attribute: AutoEquatable
  inherits: EquatableBodyView
"""

private let literalText = """
id: literal-text
message: m
select:
  call:
    callee: Text
    argument: { kind: [string, interpolation], value: '/[ぁ-ん]/' }
    not:
      any:
        - preview: true
        - condition: DEBUG
"""

@Suite struct ViewAsStructTests {
    @Test func computedPropertyAndFunctionReturningViewAreViolations() throws {
        let found = try violations(viewAsStruct, """
        struct A: View {
            var body: some View { header }
            var header: some View { Text("a") }
            func footer() -> some View { Text("b") }
        }
        """)
        #expect(found.map(\.line) == [3, 4])
    }

    @Test func membersDeclaredInAnExtensionOfTheViewCountToo() throws {
        let found = try violations(viewAsStruct, [
            "A.swift": "struct A: View { var body: some View { EmptyView() } }",
            "A+Parts.swift": "extension A { var header: some View { EmptyView() } }",
        ])
        #expect(found.map(\.file) == ["A+Parts.swift"])
    }

    @Test func modifiersOnViewItselfAndFileLevelFunctionsAreDistinguished() throws {
        let found = try violations(viewAsStruct, """
        extension View { func card() -> some View { self } }
        func makeRow() -> some View { EmptyView() }
        """)
        #expect(found.map(\.line) == [2])
    }

    @Test func storedPropertyWithViewTypeIsNotSelected() throws {
        let found = try violations(viewAsStruct, "struct A { let content: some View = EmptyView() }")
        #expect(found.isEmpty)
    }

    @Test func previewIsExcluded() throws {
        let found = try violations(viewAsStruct, """
        #Preview { struct P: View { var body: some View { x }; var x: some View { EmptyView() } }; return P() }
        """)
        #expect(found.isEmpty)
    }
}

@Suite struct ClosureViewTests {
    @Test func directClosurePropertyRequiresBothMacroAndProtocol() throws {
        let source = """
        struct A: View { let onTap: () -> Void; var body: some View { EmptyView() } }
        @AutoEquatable struct B: View { let onTap: () -> Void; var body: some View { EmptyView() } }
        @AutoEquatable struct C: EquatableBodyView, View { let onTap: () -> Void; var equatableBody: some View { EmptyView() } }
        """
        #expect(try violations(closureView, source).map(\.line) == [1, 2])
    }

    @Test func typealiasInAnotherFileIsResolved() throws {
        let found = try violations(closureView, [
            "Handler.swift": "typealias Handler = @MainActor (Int) -> Void",
            "A.swift": "struct A: View { let onTap: Handler?; var body: some View { EmptyView() } }",
        ])
        #expect(found.map(\.file) == ["A.swift"])
    }

    @Test func typealiasNestedInTheOwnerWinsOverTopLevel() throws {
        let found = try violations(closureView, [
            "Top.swift": "typealias Action = () -> Void",
            "A.swift": """
            struct A: View {
                typealias Action = String
                let action: Action
                var body: some View { EmptyView() }
            }
            """,
        ])
        #expect(found.isEmpty)
    }

    @Test func ambiguousTopLevelTypealiasIsNotTreatedAsClosure() throws {
        let found = try violations(closureView, [
            "One.swift": "typealias Action = () -> Void",
            "Two.swift": "typealias Action = String",
            "A.swift": "struct A: View { let action: Action; var body: some View { EmptyView() } }",
        ])
        #expect(found.isEmpty)
    }

    @Test func conformanceDeclaredInAnExtensionElsewhereIsMerged() throws {
        let found = try violations(closureView, [
            "A.swift": "struct A { let onTap: () -> Void; var body: some View { EmptyView() } }",
            "A+View.swift": "extension A: View {}",
        ])
        #expect(found.map(\.file) == ["A.swift"])
    }

    @Test func wrappersExcludeTheType() throws {
        let found = try violations(closureView, """
        struct A: View { @Binding var on: Bool; let onTap: () -> Void; var body: some View { EmptyView() } }
        """)
        #expect(found.isEmpty)
    }

    @Test func ignoreCommentSuppressesOnlyTheNamedRule() throws {
        let rule = try Rule.parse(yaml: closureView, source: "test")
        let facts = FactExtractor.extract(source: """
        // archlint-ignore: closure-view 外部 SDK の View を包むため
        struct A: View { let onTap: () -> Void; var body: some View { EmptyView() } }
        // archlint-ignore: other-rule
        struct B: View { let onTap: () -> Void; var body: some View { EmptyView() } }
        """, path: "Test.swift", module: "")
        let evaluation = Evaluator.evaluate([rule], on: FactSet(files: [facts]), applyFileFilters: false)
        #expect(evaluation.diagnostics.map(\.line) == [4])
        #expect(evaluation.suppressed["closure-view"] == 1)
    }
}

@Suite struct CallTests {
    @Test func literalAndLocalLetAreDetected() throws {
        let found = try violations(literalText, """
        func f(count: Int) {
            Text("ひらがな")
            Text("のこり\\(count)")
            Text("\\(count)")
            let title = "たいとる"
            Text(title)
            Text(L10n.title)
        }
        """)
        #expect(found.map(\.line) == [2, 3, 6])
    }

    @Test func nestedConditionalCompilationKeepsTheDebugBranch() throws {
        let found = try violations(literalText, """
        func f() {
            #if DEBUG
            #if os(iOS)
            Text("でばっぐ")
            #endif
            Text("でばっぐ")
            #else
            Text("ほんばん")
            #endif
        }
        """)
        #expect(found.map(\.line) == [8])
    }

    @Test func previewIsExcluded() throws {
        let found = try violations(literalText, """
        #Preview { Text("ぷれびゅー") }
        struct P: PreviewProvider { static var previews: some View { Text("ぷれびゅー") } }
        """)
        #expect(found.isEmpty)
    }
}

@Suite struct RuleParsingTests {
    @Test func unknownKeyIsRejected() {
        #expect(throws: ConfigError.self) {
            try Rule.parse(yaml: """
            id: r
            message: m
            select:
              member: { retuns: { opaque: View } }
            """, source: "test")
        }
    }

    @Test func selectNeedsExactlyOneEntity() {
        #expect(throws: ConfigError.self) {
            try Rule.parse(yaml: "id: r\nmessage: m\nselect: { type: {}, member: {} }", source: "test")
        }
    }

    @Test func regexAndListMatch() throws {
        let found = try violations("""
        id: r
        message: m
        select:
          type: { name: ['/^Foo/', Bar] }
        """, "struct FooView {}\nstruct Bar {}\nstruct Baz {}")
        #expect(found.map(\.line) == [1, 2])
    }
}

@Suite struct SyntaxErrorTests {
    @Test func brokenFileReportsTheLine() {
        let facts = FactExtractor.extract(source: "struct A {\n  var x: = 1\n}", path: "A.swift", module: "")
        #expect(facts.syntaxErrors.contains(2))
    }

    @Test func validFileHasNoErrors() {
        let facts = FactExtractor.extract(source: "struct A { var x = 1 }", path: "A.swift", module: "")
        #expect(facts.syntaxErrors.isEmpty)
    }
}

@Suite struct GlobTests {
    @Test func doubleStarMatchesZeroOrMoreDirectories() throws {
        let glob = try Glob("Sources/**/*.swift")
        #expect(glob.matches("Sources/A.swift"))
        #expect(glob.matches("Sources/a/b/A.swift"))
        #expect(!glob.matches("Tests/A.swift"))
        #expect(!(try Glob("Sources/*.swift")).matches("Sources/a/A.swift"))
    }
}

@Suite struct BaselineTests {
    private func diagnostic(_ key: String) -> Diagnostic {
        Diagnostic(rule: "r", severity: .error, message: "", note: nil, file: "f", line: 1, key: key)
    }

    @Test func onlyCountsAboveHeadAndBaselineAreNew() {
        let current = [diagnostic("a"), diagnostic("a"), diagnostic("b"), diagnostic("c")]
        let head = [diagnostic("a"), diagnostic("b")]
        let baseline = Baseline(counts: ["c": 1])
        let new = NewDiagnostics.select(current, head: head, baseline: baseline)
        #expect(new.map(\.key) == ["a", "a"])
    }

    @Test func fixedViolationMakesTheBaselineStaleUntilPruned() {
        let baseline = Baseline(counts: ["a": 2, "b": 1])
        let current = [diagnostic("a")]
        #expect(baseline.stale(against: current).map(\.key) == ["a", "b"])
        #expect(baseline.pruned(against: current) == Baseline(counts: ["a": 1]))
    }
}
