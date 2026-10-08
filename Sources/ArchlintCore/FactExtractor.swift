import Foundation
import SwiftParser
import SwiftSyntax

public enum FactExtractor {
    public static func extract(source: String, path: String, module: String) -> FileFacts {
        let tree = Parser.parse(source: source)
        let visitor = Visitor(path: path, module: module, tree: tree)
        visitor.walk(tree)
        var facts = visitor.facts
        if tree.hasError {
            let errors = SyntaxErrorVisitor(tree: tree)
            errors.walk(tree)
            facts.syntaxErrors = errors.lines.isEmpty ? [1] : errors.lines
        }
        return facts
    }
}

/// 構文エラーの位置を集める。欠けたトークンは sourceAccurate では辿れないので .all で走査する
private final class SyntaxErrorVisitor: SyntaxVisitor {
    var lines: [Int] = []
    private let converter: SourceLocationConverter

    init(tree: SourceFileSyntax) {
        converter = SourceLocationConverter(fileName: "", tree: tree)
        super.init(viewMode: .all)
    }

    override func visit(_ node: TokenSyntax) -> SyntaxVisitorContinueKind {
        if node.presence == .missing {
            lines.append(converter.location(for: node.position).line)
        }
        return .visitChildren
    }

    override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
        lines.append(converter.location(for: node.positionAfterSkippingLeadingTrivia).line)
        return .skipChildren
    }
}

private final class Visitor: SyntaxVisitor {
    var facts: FileFacts
    private let converter: SourceLocationConverter

    private enum Scope {
        case type(qualifiedName: String)
        case `extension`(extendedType: String)
        case member(name: String, signature: String)
    }

    private var scopes: [Scope] = []
    /// メンバーの scope を積んだか。ローカルな関数・変数は積まない（呼び出しの所有メンバーにしないため）
    private var memberPushed: [Bool] = []
    private var conditions: [[String]] = []
    private var previewDepth = 0

    init(path: String, module: String, tree: SourceFileSyntax) {
        facts = FileFacts(path: path, module: module)
        converter = SourceLocationConverter(fileName: path, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    private var context: SourceContext {
        SourceContext(preview: previewDepth > 0, conditions: conditions.flatMap { $0 })
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    /// 型の中なら修飾名、extension の中なら拡張先
    private var ownerName: String? {
        for scope in scopes.reversed() {
            switch scope {
            case .type(let name): return name
            case .extension(let name): return name
            case .member: continue
            }
        }
        return nil
    }

    private var member: (name: String, signature: String)? {
        for scope in scopes.reversed() {
            if case .member(let name, let signature) = scope { return (name, signature) }
        }
        return nil
    }

    private func pushMember(_ node: some SyntaxProtocol, name: String, signature: String) {
        let isMember = isMemberDecl(node) || isFileLevelDecl(node)
        memberPushed.append(isMember)
        if isMember { scopes.append(.member(name: name, signature: signature)) }
    }

    private func popMember() {
        if memberPushed.removeLast() { scopes.removeLast() }
    }

    static func signature(_ parameters: [Parameter]) -> String {
        "(" + parameters.map { "\($0.label):" }.joined() + ")"
    }

    private func qualified(_ name: String) -> String {
        ownerName.map { "\($0).\(name)" } ?? name
    }

    /// メンバーとして宣言されたか（関数の中のローカルな宣言を除く）
    private func isMemberDecl(_ node: some SyntaxProtocol) -> Bool {
        node.parent?.is(MemberBlockItemSyntax.self) == true
    }

    private func isFileLevelDecl(_ node: some SyntaxProtocol) -> Bool {
        guard let item = node.parent?.as(CodeBlockItemSyntax.self) else { return false }
        // #if の中でもファイル直下として扱う
        var current: Syntax? = item.parent
        while let node = current {
            if node.is(SourceFileSyntax.self) { return true }
            if node.is(IfConfigClauseSyntax.self) || node.is(IfConfigDeclSyntax.self)
                || node.is(IfConfigClauseListSyntax.self) || node.is(CodeBlockItemListSyntax.self)
                || node.is(CodeBlockItemSyntax.self) {
                current = node.parent
                continue
            }
            return false
        }
        return false
    }

    // MARK: - #if と #Preview

    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        conditions.append(Self.conditions(of: node))
        return .visitChildren
    }

    override func visitPost(_ node: IfConfigClauseSyntax) {
        conditions.removeLast()
    }

    static func conditions(of clause: IfConfigClauseSyntax) -> [String] {
        var result: [String] = []
        if let list = clause.parent?.as(IfConfigClauseListSyntax.self) {
            for previous in list {
                if previous.id == clause.id { break }
                if let condition = previous.condition {
                    result.append(negate(condition.trimmedDescription))
                }
            }
        }
        if let condition = clause.condition {
            result.append(condition.trimmedDescription)
        }
        return result
    }

    static func negate(_ condition: String) -> String {
        if condition.hasPrefix("!"), !condition.contains(" ") {
            return String(condition.dropFirst())
        }
        return condition.contains(" ") ? "!(\(condition))" : "!\(condition)"
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "Preview" { previewDepth += 1 }
        return .visitChildren
    }

    override func visitPost(_ node: MacroExpansionDeclSyntax) {
        if node.macroName.text == "Preview" { previewDepth -= 1 }
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "Preview" { previewDepth += 1 }
        return .visitChildren
    }

    override func visitPost(_ node: MacroExpansionExprSyntax) {
        if node.macroName.text == "Preview" { previewDepth -= 1 }
    }

    // MARK: - 型

    private func enterType(
        kind: TypeKind,
        name: String,
        attributes: AttributeListSyntax,
        inheritance: InheritanceClauseSyntax?,
        node: some SyntaxProtocol
    ) {
        let inherits = Self.inheritedNames(inheritance)
        let isPreviewProvider = inherits.contains("PreviewProvider")
        if isPreviewProvider { previewDepth += 1 }
        facts.types.append(TypeFact(
            kind: kind,
            name: name,
            qualifiedName: qualified(name),
            attributes: Self.attributeNames(attributes),
            inherits: inherits,
            file: facts.path,
            line: line(node),
            context: context,
            ignores: Self.ignores(node)
        ))
        scopes.append(.type(qualifiedName: qualified(name)))
    }

    private func leaveType(_ inheritance: InheritanceClauseSyntax?) {
        scopes.removeLast()
        if Self.inheritedNames(inheritance).contains("PreviewProvider") { previewDepth -= 1 }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(kind: .struct, name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause, node: node)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { leaveType(node.inheritanceClause) }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(kind: .class, name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause, node: node)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { leaveType(node.inheritanceClause) }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(kind: .enum, name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause, node: node)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { leaveType(node.inheritanceClause) }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(kind: .actor, name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause, node: node)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { leaveType(node.inheritanceClause) }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(kind: .protocol, name: node.name.text, attributes: node.attributes, inheritance: node.inheritanceClause, node: node)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) { leaveType(node.inheritanceClause) }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = Self.typeRef(node.extendedType)
        let extendedName = extended.name.map { _ in Self.stripGenerics(node.extendedType.trimmedDescription) }
            ?? node.extendedType.trimmedDescription
        let inherits = Self.inheritedNames(node.inheritanceClause)
        facts.extensions.append(ExtensionFact(
            extendedType: extendedName,
            inherits: inherits,
            file: facts.path,
            line: line(node),
            context: context
        ))
        if inherits.contains("PreviewProvider") { previewDepth += 1 }
        scopes.append(.extension(extendedType: extendedName))
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        scopes.removeLast()
        if Self.inheritedNames(node.inheritanceClause).contains("PreviewProvider") { previewDepth -= 1 }
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if isMemberDecl(node) || isFileLevelDecl(node) {
            facts.typeAliases.append(TypeAliasFact(
                name: node.name.text,
                owner: ownerName,
                target: Self.typeRef(node.initializer.value),
                file: facts.path
            ))
        }
        return .visitChildren
    }

    // MARK: - メンバー

    private var declaredIn: DeclaredIn? {
        guard let last = scopes.last else { return .file }
        switch last {
        case .type: return .type
        case .extension: return .extension
        case .member: return nil
        }
    }

    private func appendMember(
        kind: MemberKind,
        name: String,
        stored: Bool,
        type: TypeRef?,
        returns: TypeRef?,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        parameters: [Parameter],
        node: some SyntaxProtocol
    ) {
        guard isMemberDecl(node) || isFileLevelDecl(node), let declaredIn else { return }
        let modifierNames = modifiers.map(\.name.text)
        facts.members.append(MemberFact(
            kind: kind,
            name: name,
            declaredIn: declaredIn,
            owner: declaredIn == .file ? nil : ownerName,
            isStatic: modifierNames.contains("static") || modifierNames.contains("class"),
            stored: stored,
            type: type,
            returns: returns,
            attributes: Self.attributeNames(attributes),
            modifiers: modifierNames,
            parameters: parameters,
            file: facts.path,
            line: line(node),
            context: context,
            ignores: Self.ignores(node)
        ))
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        appendMember(
            kind: .func,
            name: node.name.text,
            stored: false,
            type: nil,
            returns: node.signature.returnClause.map { Self.typeRef($0.type) },
            attributes: node.attributes,
            modifiers: node.modifiers,
            parameters: Self.parameters(node.signature.parameterClause),
            node: node
        )
        pushMember(node, name: node.name.text, signature: Self.signature(Self.parameters(node.signature.parameterClause)))
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { popMember() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        appendMember(
            kind: .`init`,
            name: "init",
            stored: false,
            type: nil,
            returns: nil,
            attributes: node.attributes,
            modifiers: node.modifiers,
            parameters: Self.parameters(node.signature.parameterClause),
            node: node
        )
        pushMember(node, name: "init", signature: Self.signature(Self.parameters(node.signature.parameterClause)))
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) { popMember() }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        appendMember(
            kind: .subscript,
            name: "subscript",
            stored: false,
            type: nil,
            returns: Self.typeRef(node.returnClause.type),
            attributes: node.attributes,
            modifiers: node.modifiers,
            parameters: Self.parameters(node.parameterClause),
            node: node
        )
        pushMember(node, name: "subscript", signature: Self.signature(Self.parameters(node.parameterClause)))
        return .visitChildren
    }

    override func visitPost(_ node: SubscriptDeclSyntax) { popMember() }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isLet = node.bindingSpecifier.tokenKind == .keyword(.let)
        var names: [String] = []
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = identifier.identifier.text
            names.append(name)
            let stored = Self.isStored(binding)
            let type = binding.typeAnnotation.map { Self.typeRef($0.type) }
            appendMember(
                kind: isLet ? .let : .var,
                name: name,
                stored: stored,
                type: type,
                returns: stored ? nil : type,
                attributes: node.attributes,
                modifiers: node.modifiers,
                parameters: [],
                node: node
            )
        }
        pushMember(node, name: names.first ?? "_", signature: "")
        return .visitChildren
    }

    override func visitPost(_ node: VariableDeclSyntax) { popMember() }

    // MARK: - 呼び出し

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calleeText = node.calledExpression.trimmedDescription
        let callee: String
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            callee = reference.baseName.text
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            callee = member.declName.baseName.text
        } else {
            callee = calleeText
        }
        var arguments = node.arguments.map { argument in
            Self.argument(label: argument.label?.text ?? "_", expression: argument.expression)
        }
        if let trailing = node.trailingClosure {
            arguments.append(Argument(label: "_", kind: .closure, value: nil, text: trailing.trimmedDescription))
        }
        facts.calls.append(CallFact(
            callee: callee,
            calleeText: calleeText,
            arguments: arguments,
            ownerType: ownerName,
            ownerMember: member?.name,
            ownerSignature: member?.signature,
            file: facts.path,
            line: line(node),
            context: context,
            ignores: Self.ignores(node)
        ))
        return .visitChildren
    }

    // MARK: - 構文から値を取り出す

    static func argument(label: String, expression: ExprSyntax) -> Argument {
        let text = expression.trimmedDescription
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return stringArgument(label: label, literal: literal, text: text)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            if let literal = localStringLiteral(named: reference.baseName.text, before: expression) {
                return stringArgument(label: label, literal: literal, text: text)
            }
            return Argument(label: label, kind: .identifier, value: nil, text: text)
        }
        if expression.is(ClosureExprSyntax.self) {
            return Argument(label: label, kind: .closure, value: nil, text: text)
        }
        return Argument(label: label, kind: .other, value: nil, text: text)
    }

    private static func stringArgument(label: String, literal: StringLiteralExprSyntax, text: String) -> Argument {
        var value = ""
        var interpolated = false
        for segment in literal.segments {
            if let string = segment.as(StringSegmentSyntax.self) {
                value += string.content.text
            } else {
                interpolated = true
            }
        }
        return Argument(label: label, kind: interpolated ? .interpolation : .string, value: value, text: text)
    }

    /// 呼び出しより前に、同じ関数の中で `let name = "..."` と書いた文字列リテラルを探す。
    /// 再代入できる `var` や、ブロックの外の値は追わない（構文だけでは値が決まらないため）
    static func localStringLiteral(named name: String, before expression: ExprSyntax) -> StringLiteralExprSyntax? {
        var child = Syntax(expression)
        var current = expression.parent
        while let node = current {
            if node.is(FunctionDeclSyntax.self) || node.is(MemberBlockSyntax.self) || node.is(SourceFileSyntax.self) {
                return nil
            }
            if let list = node.as(CodeBlockItemListSyntax.self) {
                // 最も近い（後の）宣言だけを見る。内側の宣言が文字列リテラルでなければ、外側のリテラルは使わない
                var nearest: VariableDeclSyntax?
                var nearestBinding: PatternBindingSyntax?
                for item in list {
                    if item.id == child.id { break }
                    guard let variable = item.item.as(VariableDeclSyntax.self) else { continue }
                    for binding in variable.bindings
                    where binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == name {
                        nearest = variable
                        nearestBinding = binding
                    }
                }
                if let nearest, let nearestBinding {
                    guard nearest.bindingSpecifier.tokenKind == .keyword(.let) else { return nil }
                    return nearestBinding.initializer?.value.as(StringLiteralExprSyntax.self)
                }
            }
            child = node
            current = node.parent
        }
        return nil
    }

    static func isStored(_ binding: PatternBindingSyntax) -> Bool {
        guard let block = binding.accessorBlock else { return true }
        switch block.accessors {
        case .getter:
            return false
        case .accessors(let list):
            return list.allSatisfy {
                let text = $0.accessorSpecifier.text
                return text == "willSet" || text == "didSet"
            }
        }
    }

    static func parameters(_ clause: FunctionParameterClauseSyntax) -> [Parameter] {
        clause.parameters.map { parameter in
            Parameter(
                label: parameter.firstName.text,
                name: (parameter.secondName ?? parameter.firstName).text,
                type: typeRef(parameter.type)
            )
        }
    }

    static func attributeNames(_ attributes: AttributeListSyntax) -> [String] {
        attributes.compactMap { element in
            element.as(AttributeSyntax.self).map { lastComponent(stripGenerics($0.attributeName.trimmedDescription)) }
        }
    }

    static func inheritedNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        clause?.inheritedTypes.compactMap { typeRef($0.type).name } ?? []
    }

    static func typeRef(_ type: TypeSyntax) -> TypeRef {
        var ref = TypeRef(text: type.trimmedDescription, name: nil, opaque: nil, function: false, optional: false)
        var current = type
        while true {
            if let attributed = current.as(AttributedTypeSyntax.self) {
                current = attributed.baseType
            } else if let optional = current.as(OptionalTypeSyntax.self) {
                ref.optional = true
                current = optional.wrappedType
            } else if let unwrapped = current.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
                ref.optional = true
                current = unwrapped.wrappedType
            } else if let tuple = current.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
                current = only.type
            } else {
                break
            }
        }
        if current.is(FunctionTypeSyntax.self) {
            ref.function = true
        } else if let identifier = current.as(IdentifierTypeSyntax.self) {
            ref.name = identifier.name.text
        } else if let member = current.as(MemberTypeSyntax.self) {
            ref.name = member.name.text
        } else if let some = current.as(SomeOrAnyTypeSyntax.self) {
            if some.someOrAnySpecifier.tokenKind == .keyword(.some) {
                ref.opaque = typeRef(some.constraint).name ?? some.constraint.trimmedDescription
            }
        }
        return ref
    }

    static func stripGenerics(_ text: String) -> String {
        guard let index = text.firstIndex(of: "<") else { return text }
        return String(text[..<index])
    }

    static func lastComponent(_ text: String) -> String {
        text.split(separator: ".").last.map(String.init) ?? text
    }

    /// 直前のコメントに書いた `archlint-ignore: id1,id2 理由`。空行を挟んだコメントは対象にしない
    static func ignores(_ node: some SyntaxProtocol) -> [String] {
        var comments: [String] = []
        var newlines = 0
        for piece in node.leadingTrivia.reversed() {
            switch piece {
            case .newlines(let count), .carriageReturnLineFeeds(let count):
                newlines += count
            case .carriageReturns(let count):
                newlines += count
            case .lineComment(let comment), .blockComment(let comment), .docLineComment(let comment), .docBlockComment(let comment):
                comments.append(comment)
                newlines = 0
            default:
                break
            }
            if newlines >= 2 { break }
        }
        return comments.flatMap { comment -> [String] in
            guard let range = comment.range(of: "archlint-ignore:") else { return [] }
            return ignoreIDs(String(comment[range.upperBound...]))
        }
    }

    /// 最初の語をカンマ区切りの ID として読む。後ろは理由（英語でもよい）
    static func ignoreIDs(_ text: String) -> [String] {
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return [] }
        return first.split(separator: ",").map(String.init).filter { !$0.isEmpty && $0 != "*/" }
    }
}
