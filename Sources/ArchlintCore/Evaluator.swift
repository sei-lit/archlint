public struct Diagnostic: Hashable, Sendable {
    public let rule: String
    public let severity: Severity
    public let message: String
    public let note: String?
    public let file: String
    public let line: Int
    /// baseline と HEAD との突き合わせに使うキー。行番号を含めない（行の移動で別の違反にならないように）
    public let key: String
}

struct EntityLocation {
    let file: String
    let line: Int
    let module: String
    let context: SourceContext
    let ignores: [String]
}

extension FactSet {
    func location(_ kind: EntityKind, _ index: Int) -> EntityLocation {
        switch kind {
        case .type:
            let type = types[index]
            return EntityLocation(file: type.fact.file, line: type.fact.line, module: type.module, context: type.fact.context, ignores: type.fact.ignores)
        case .member:
            let member = members[index]
            return EntityLocation(file: member.fact.file, line: member.fact.line, module: member.module, context: member.fact.context, ignores: member.fact.ignores)
        case .call:
            let call = calls[index]
            return EntityLocation(file: call.fact.file, line: call.fact.line, module: call.module, context: call.fact.context, ignores: call.fact.ignores)
        }
    }

    func count(_ kind: EntityKind) -> Int {
        switch kind {
        case .type: types.count
        case .member: members.count
        case .call: calls.count
        }
    }

    /// 違反を同じ場所の別の違反と区別する名前。型・メンバー・引数ラベル・呼び出す名前で作る
    func symbol(_ kind: EntityKind, _ index: Int) -> String {
        switch kind {
        case .type:
            return "type \(types[index].fact.qualifiedName)"
        case .member:
            let member = members[index].fact
            let labels = member.parameters.map { "\($0.label):" }.joined()
            let signature = member.kind == .func || member.kind == .`init` || member.kind == .subscript ? "(\(labels))" : ""
            return "member \(member.owner.map { "\($0)." } ?? "")\(member.name)\(signature)"
        case .call:
            let call = calls[index].fact
            let labels = call.arguments.map { "\($0.label):" }.joined()
            return "call \(call.ownerType.map { "\($0)." } ?? "")\(call.ownerMember ?? "_")\(call.ownerSignature ?? "") -> \(call.callee)(\(labels))"
        }
    }
}

public struct Evaluation {
    public var diagnostics: [Diagnostic] = []
    /// `archlint-ignore` で抑制した件数（ルールごと）
    public var suppressed: [String: Int] = [:]
}

public enum Evaluator {
    public static func evaluate(_ rules: [Rule], on set: FactSet, applyFileFilters: Bool = true) -> Evaluation {
        var result = Evaluation()
        for rule in rules {
            for index in 0..<set.count(rule.kind) {
                let location = set.location(rule.kind, index)
                if applyFileFilters, !rule.applies(to: location.file) { continue }
                guard rule.select(set, index) else { continue }
                if let require = rule.require, require(set, index) { continue }
                if location.ignores.contains(rule.id) {
                    result.suppressed[rule.id, default: 0] += 1
                    continue
                }
                result.diagnostics.append(Diagnostic(
                    rule: rule.id,
                    severity: rule.severity,
                    message: rule.message,
                    note: rule.note,
                    file: location.file,
                    line: location.line,
                    key: "\(rule.id) | \(location.file) | \(set.symbol(rule.kind, index))"
                ))
            }
        }
        result.diagnostics.sort { ($0.file, $0.line, $0.rule) < ($1.file, $1.line, $1.rule) }
        return result
    }
}
