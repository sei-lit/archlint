import Foundation
import Yams

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Severity: String, Sendable {
    case error, warning
}

public enum EntityKind: String, Sendable {
    case type, member, call
}

typealias EntityPredicate = (FactSet, Int) -> Bool

public struct Rule {
    public let id: String
    public let severity: Severity
    public let message: String
    public let note: String?
    public let kind: EntityKind
    let files: [Glob]
    let ignores: [Glob]
    let select: EntityPredicate
    let require: EntityPredicate?

    static let keys: Set<String> = ["id", "severity", "message", "note", "files", "ignores", "select", "require"]

    public static func load(path: String) throws -> Rule {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try parse(yaml: text, source: path)
    }

    public static func parse(yaml: String, source: String) throws -> Rule {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ConfigError("\(source): ルールは YAML の mapping で書く")
        }
        try checkKeys(root, allowed: keys, at: source)
        guard let id = root["id"] as? String, !id.isEmpty else { throw ConfigError("\(source): id が無い") }
        let at = "\(source) (\(id))"
        let severity: Severity
        if let raw = root["severity"] {
            guard let value = (raw as? String).flatMap(Severity.init(rawValue:)) else {
                throw ConfigError("\(at): severity は error か warning")
            }
            severity = value
        } else {
            severity = .error
        }
        guard let message = root["message"] as? String else { throw ConfigError("\(at): message が無い") }
        guard let select = root["select"] as? [String: Any], select.count == 1, let (kindName, body) = select.first,
              let kind = EntityKind(rawValue: kindName) else {
            throw ConfigError("\(at): select には type / member / call のどれか 1 つを書く")
        }
        let compiler = PredicateCompiler(source: at)
        return Rule(
            id: id,
            severity: severity,
            message: message,
            note: root["note"] as? String,
            kind: kind,
            files: try globs(root["files"], at: "\(at) files"),
            ignores: try globs(root["ignores"], at: "\(at) ignores"),
            select: try compiler.compile(body, kind: kind, path: "select.\(kindName)"),
            require: try root["require"].map { try compiler.compile($0, kind: kind, path: "require") }
        )
    }

    func applies(to file: String) -> Bool {
        if !files.isEmpty, !files.contains(where: { $0.matches(file) }) { return false }
        return !ignores.contains(where: { $0.matches(file) })
    }
}

func checkKeys(_ map: [String: Any], allowed: Set<String>, at path: String) throws {
    // 書き間違えたキーを無視すると条件が消えて全件が通るので、知らないキーは設定の誤りにする
    for key in map.keys where !allowed.contains(key) {
        throw ConfigError("\(path): 知らないキー `\(key)`（使えるキー: \(allowed.sorted().joined(separator: ", "))）")
    }
}

func globs(_ value: Any?, at path: String) throws -> [Glob] {
    guard let value else { return [] }
    if let single = value as? String { return [try Glob(single)] }
    guard let list = value as? [Any] else { throw ConfigError("\(path): glob の配列で書く") }
    return try list.map { item in
        guard let text = item as? String else { throw ConfigError("\(path): glob は文字列") }
        return try Glob(text)
    }
}

// MARK: - 値の照合

/// 文字列は完全一致、`/.../` は正規表現、配列はいずれか
struct StringMatcher {
    private enum Kind {
        case exact(String)
        case regex(NSRegularExpression)
    }

    private let alternatives: [Kind]

    init(_ value: Any, at path: String) throws {
        if let list = value as? [Any] {
            alternatives = try list.map { try Self.kind($0, at: path) }
        } else {
            alternatives = [try Self.kind(value, at: path)]
        }
    }

    private static func kind(_ value: Any, at path: String) throws -> Kind {
        let text: String
        switch value {
        case let string as String: text = string
        case let number as Int: text = String(number)
        case let bool as Bool: text = String(bool)
        default: throw ConfigError("\(path): 文字列か、文字列の配列で書く")
        }
        if text.count >= 2, text.hasPrefix("/"), text.hasSuffix("/") {
            do {
                return .regex(try NSRegularExpression(pattern: String(text.dropFirst().dropLast())))
            } catch {
                throw ConfigError("\(path): 正規表現 \(text) を読めない")
            }
        }
        return .exact(text)
    }

    func matches(_ value: String?) -> Bool {
        guard let value else { return false }
        return alternatives.contains { kind in
            switch kind {
            case .exact(let text): return text == value
            case .regex(let regex):
                return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
        }
    }

    func matchesAny(_ values: [String]) -> Bool {
        values.contains(where: matches)
    }
}

func bool(_ value: Any, at path: String) throws -> Bool {
    guard let result = value as? Bool else { throw ConfigError("\(path): true か false で書く") }
    return result
}

// MARK: - 条件の組み立て

struct PredicateCompiler {
    let source: String

    private static let commonKeys: Set<String> = ["all", "any", "not", "file", "module", "preview", "condition"]
    private static let typeKeys: Set<String> = ["kind", "name", "qualifiedName", "attribute", "inherits", "has"]
    private static let memberKeys: Set<String> = [
        "kind", "name", "declaredIn", "owner", "static", "stored", "type", "returns",
        "attribute", "modifier", "parameter", "in",
    ]
    private static let callKeys: Set<String> = ["callee", "calleeText", "argument", "in"]

    func compile(_ value: Any, kind: EntityKind, path: String) throws -> EntityPredicate {
        let at = "\(source) \(path)"
        guard let map = value as? [String: Any] else { throw ConfigError("\(at): 条件は mapping で書く") }
        let specific: Set<String>
        switch kind {
        case .type: specific = Self.typeKeys
        case .member: specific = Self.memberKeys
        case .call: specific = Self.callKeys
        }
        try checkKeys(map, allowed: Self.commonKeys.union(specific), at: at)
        var predicates: [EntityPredicate] = []
        for (key, body) in map.sorted(by: { $0.key < $1.key }) {
            let keyPath = "\(path).\(key)"
            if let common = try compileCommon(key, body, kind: kind, path: keyPath) {
                predicates.append(common)
                continue
            }
            switch kind {
            case .type: predicates.append(try compileType(key, body, path: keyPath))
            case .member: predicates.append(try compileMember(key, body, path: keyPath))
            case .call: predicates.append(try compileCall(key, body, path: keyPath))
            }
        }
        return { set, index in predicates.allSatisfy { $0(set, index) } }
    }

    private func list(_ value: Any, at path: String) throws -> [Any] {
        guard let list = value as? [Any], !list.isEmpty else { throw ConfigError("\(source) \(path): 条件の配列で書く") }
        return list
    }

    private func compileCommon(_ key: String, _ body: Any, kind: EntityKind, path: String) throws -> EntityPredicate? {
        let at = "\(source) \(path)"
        switch key {
        case "all":
            let parts = try list(body, at: path).enumerated().map { try compile($1, kind: kind, path: "\(path)[\($0)]") }
            return { set, index in parts.allSatisfy { $0(set, index) } }
        case "any":
            let parts = try list(body, at: path).enumerated().map { try compile($1, kind: kind, path: "\(path)[\($0)]") }
            return { set, index in parts.contains { $0(set, index) } }
        case "not":
            let inner = try compile(body, kind: kind, path: path)
            return { set, index in !inner(set, index) }
        case "file":
            let patterns = try globs(body, at: at)
            return { set, index in
                let file = set.location(kind, index).file
                return patterns.contains { $0.matches(file) }
            }
        case "module":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.location(kind, index).module) }
        case "preview":
            let expected = try bool(body, at: at)
            return { set, index in set.location(kind, index).context.preview == expected }
        case "condition":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matchesAny(set.location(kind, index).context.conditions) }
        default:
            return nil
        }
    }

    private func compileType(_ key: String, _ body: Any, path: String) throws -> EntityPredicate {
        let at = "\(source) \(path)"
        switch key {
        case "kind":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.types[index].fact.kind.rawValue) }
        case "name":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.types[index].fact.name) }
        case "qualifiedName":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.types[index].fact.qualifiedName) }
        case "attribute":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matchesAny(set.types[index].fact.attributes) }
        case "inherits":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matchesAny(set.types[index].inherits) }
        case "has":
            guard let map = body as? [String: Any], map.count == 1, let (name, inner) = map.first else {
                throw ConfigError("\(at): has には member か call を 1 つ書く")
            }
            switch name {
            case "member":
                let predicate = try compile(inner, kind: .member, path: "\(path).member")
                return { set, index in set.types[index].memberIndices.contains { predicate(set, $0) } }
            case "call":
                let predicate = try compile(inner, kind: .call, path: "\(path).call")
                return { set, index in set.types[index].callIndices.contains { predicate(set, $0) } }
            default:
                throw ConfigError("\(at): has には member か call を書く")
            }
        default:
            throw ConfigError("\(at): 知らないキー")
        }
    }

    private func compileMember(_ key: String, _ body: Any, path: String) throws -> EntityPredicate {
        let at = "\(source) \(path)"
        switch key {
        case "kind":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.members[index].fact.kind.rawValue) }
        case "name":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.members[index].fact.name) }
        case "declaredIn":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.members[index].fact.declaredIn.rawValue) }
        case "owner":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.members[index].fact.owner) }
        case "static":
            let expected = try bool(body, at: at)
            return { set, index in set.members[index].fact.isStatic == expected }
        case "stored":
            let expected = try bool(body, at: at)
            return { set, index in set.members[index].fact.stored == expected }
        case "type":
            let predicate = try compileTypeRef(body, path: path)
            return { set, index in
                let member = set.members[index]
                return member.fact.type.map { predicate($0, member.typeIsFunction) } ?? false
            }
        case "returns":
            let predicate = try compileTypeRef(body, path: path)
            return { set, index in
                let member = set.members[index]
                return member.fact.returns.map { predicate($0, member.returnsIsFunction) } ?? false
            }
        case "attribute":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matchesAny(set.members[index].fact.attributes) }
        case "modifier":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matchesAny(set.members[index].fact.modifiers) }
        case "parameter":
            let predicate = try compileParameter(body, path: path)
            return { set, index in
                let member = set.members[index]
                return member.fact.parameters.contains { parameter in
                    let resolved = parameter.type.map { set.isFunction($0, owner: member.fact.owner, module: member.module) } ?? false
                    return predicate(parameter, resolved)
                }
            }
        case "in":
            let predicate = try compileIn(body, path: path, allowMember: false)
            return { set, index in predicate(set, set.members[index].ownerType, nil) }
        default:
            throw ConfigError("\(at): 知らないキー")
        }
    }

    private func compileCall(_ key: String, _ body: Any, path: String) throws -> EntityPredicate {
        let at = "\(source) \(path)"
        switch key {
        case "callee":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.calls[index].fact.callee) }
        case "calleeText":
            let matcher = try StringMatcher(body, at: at)
            return { set, index in matcher.matches(set.calls[index].fact.calleeText) }
        case "argument":
            let predicate = try compileArgument(body, path: path)
            return { set, index in set.calls[index].fact.arguments.contains(where: predicate) }
        case "in":
            let predicate = try compileIn(body, path: path, allowMember: true)
            return { set, index in predicate(set, set.calls[index].ownerType, set.calls[index].ownerMember) }
        default:
            throw ConfigError("\(at): 知らないキー")
        }
    }

    /// 囲む型・メンバーに対する条件。ソースの中で宣言されていない型（`extension View` の View など）には当たらない
    private func compileIn(_ body: Any, path: String, allowMember: Bool) throws -> (FactSet, Int?, Int?) -> Bool {
        let at = "\(source) \(path)"
        guard let map = body as? [String: Any], !map.isEmpty else { throw ConfigError("\(at): in には type か member を書く") }
        try checkKeys(map, allowed: allowMember ? ["type", "member"] : ["type"], at: at)
        let type = try map["type"].map { try compile($0, kind: .type, path: "\(path).type") }
        let member = try map["member"].map { try compile($0, kind: .member, path: "\(path).member") }
        return { set, typeIndex, memberIndex in
            if let type {
                guard let typeIndex, type(set, typeIndex) else { return false }
            }
            if let member {
                guard let memberIndex, member(set, memberIndex) else { return false }
            }
            return true
        }
    }

    private func compileTypeRef(_ body: Any, path: String) throws -> (TypeRef, Bool) -> Bool {
        let at = "\(source) \(path)"
        guard let map = body as? [String: Any] else { throw ConfigError("\(at): 型の条件は mapping で書く") }
        try checkKeys(map, allowed: ["name", "text", "opaque", "function", "optional", "not", "any"], at: at)
        var predicates: [(TypeRef, Bool) -> Bool] = []
        for (key, value) in map {
            let keyAt = "\(at).\(key)"
            switch key {
            case "name":
                let matcher = try StringMatcher(value, at: keyAt)
                predicates.append { ref, _ in matcher.matches(ref.name) }
            case "text":
                let matcher = try StringMatcher(value, at: keyAt)
                predicates.append { ref, _ in matcher.matches(ref.text) }
            case "opaque":
                let matcher = try StringMatcher(value, at: keyAt)
                predicates.append { ref, _ in matcher.matches(ref.opaque) }
            case "function":
                let expected = try bool(value, at: keyAt)
                predicates.append { _, resolved in resolved == expected }
            case "optional":
                let expected = try bool(value, at: keyAt)
                predicates.append { ref, _ in ref.optional == expected }
            case "not":
                let inner = try compileTypeRef(value, path: "\(path).not")
                predicates.append { !inner($0, $1) }
            case "any":
                let parts = try list(value, at: "\(path).any").map { try compileTypeRef($0, path: "\(path).any") }
                predicates.append { ref, resolved in parts.contains { $0(ref, resolved) } }
            default:
                break
            }
        }
        return { ref, resolved in predicates.allSatisfy { $0(ref, resolved) } }
    }

    /// 引数の型が関数型かは、typealias を解決した結果（resolvedFunction）で判定する
    private func compileParameter(_ body: Any, path: String) throws -> (Parameter, Bool) -> Bool {
        let at = "\(source) \(path)"
        guard let map = body as? [String: Any] else { throw ConfigError("\(at): 引数の条件は mapping で書く") }
        try checkKeys(map, allowed: ["label", "name", "type"], at: at)
        let label = try map["label"].map { try StringMatcher($0, at: "\(at).label") }
        let name = try map["name"].map { try StringMatcher($0, at: "\(at).name") }
        let type = try map["type"].map { try compileTypeRef($0, path: "\(path).type") }
        return { parameter, resolvedFunction in
            if let label, !label.matches(parameter.label) { return false }
            if let name, !name.matches(parameter.name) { return false }
            if let type {
                guard let ref = parameter.type, type(ref, resolvedFunction) else { return false }
            }
            return true
        }
    }

    private func compileArgument(_ body: Any, path: String) throws -> (Argument) -> Bool {
        let at = "\(source) \(path)"
        guard let map = body as? [String: Any] else { throw ConfigError("\(at): 引数の条件は mapping で書く") }
        try checkKeys(map, allowed: ["label", "kind", "value", "text"], at: at)
        let label = try map["label"].map { try StringMatcher($0, at: "\(at).label") }
        let kind = try map["kind"].map { try StringMatcher($0, at: "\(at).kind") }
        let value = try map["value"].map { try StringMatcher($0, at: "\(at).value") }
        let text = try map["text"].map { try StringMatcher($0, at: "\(at).text") }
        return { argument in
            if let label, !label.matches(argument.label) { return false }
            if let kind, !kind.matches(argument.kind.rawValue) { return false }
            if let value, !value.matches(argument.value) { return false }
            if let text, !text.matches(argument.text) { return false }
            return true
        }
    }
}

// MARK: - glob

/// `**` は 0 個以上のディレクトリ、`*` と `?` は `/` を含まない
public struct Glob {
    let pattern: String
    private let regex: NSRegularExpression

    public init(_ pattern: String) throws {
        self.pattern = pattern
        var result = "^"
        var characters = Array(pattern)[...]
        while let character = characters.first {
            characters = characters.dropFirst()
            switch character {
            case "*":
                if characters.first == "*" {
                    characters = characters.dropFirst()
                    if characters.first == "/" {
                        characters = characters.dropFirst()
                        result += "(?:.*/)?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        result += "$"
        do {
            regex = try NSRegularExpression(pattern: result)
        } catch {
            throw ConfigError("glob \(pattern) を読めない")
        }
    }

    public func matches(_ path: String) -> Bool {
        regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
