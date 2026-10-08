/// 全ファイルの事実をまとめ、ファイルをまたぐ関係（extension での準拠、typealias）を解決する。
public final class FactSet {
    public let files: [FileFacts]
    public private(set) var types: [ResolvedType] = []
    public private(set) var members: [ResolvedMember] = []
    public private(set) var calls: [ResolvedCall] = []

    private var typesByName: [String: [Int]] = [:]
    private var aliases: [String: [(module: String, owner: String?, target: TypeRef)]] = [:]

    public struct ResolvedType {
        public var fact: TypeFact
        public var module: String
        /// 宣言と、全ファイルの extension での準拠を合わせたもの
        public var inherits: [String]
        public var memberIndices: [Int] = []
        public var callIndices: [Int] = []
    }

    public struct ResolvedMember {
        public var fact: MemberFact
        public var module: String
        /// 所有する型がソースの中で宣言されていればその添字
        public var ownerType: Int?
        /// typealias を解決した後で関数型か
        public var typeIsFunction: Bool
        public var returnsIsFunction: Bool
    }

    public struct ResolvedCall {
        public var fact: CallFact
        public var module: String
        public var ownerType: Int?
        public var ownerMember: Int?
    }

    public init(files: [FileFacts]) {
        self.files = files
        resolve()
    }

    private func resolve() {
        for file in files {
            for type in file.types {
                typesByName[type.qualifiedName, default: []].append(types.count)
                types.append(ResolvedType(fact: type, module: file.module, inherits: type.inherits))
            }
            for alias in file.typeAliases {
                aliases[alias.name, default: []].append((file.module, alias.owner, alias.target))
            }
        }
        for file in files {
            for ext in file.extensions {
                guard let index = lookupType(ext.extendedType, module: file.module) else { continue }
                for name in ext.inherits where !types[index].inherits.contains(name) {
                    types[index].inherits.append(name)
                }
            }
        }
        for file in files {
            var membersByOwnerAndName: [String: Int] = [:]
            for member in file.members {
                let owner = member.owner.flatMap { lookupType($0, module: file.module) }
                let index = members.count
                members.append(ResolvedMember(
                    fact: member,
                    module: file.module,
                    ownerType: owner,
                    typeIsFunction: member.type.map { isFunction($0, owner: member.owner, module: file.module) } ?? false,
                    returnsIsFunction: member.returns.map { isFunction($0, owner: member.owner, module: file.module) } ?? false
                ))
                if let owner { types[owner].memberIndices.append(index) }
                membersByOwnerAndName["\(member.owner ?? "")#\(member.name)"] = index
            }
            for call in file.calls {
                let owner = call.ownerType.flatMap { lookupType($0, module: file.module) }
                let member = call.ownerMember.flatMap { membersByOwnerAndName["\(call.ownerType ?? "")#\($0)"] }
                let index = calls.count
                calls.append(ResolvedCall(fact: call, module: file.module, ownerType: owner, ownerMember: member))
                if let owner { types[owner].callIndices.append(index) }
            }
        }
    }

    /// 修飾名で型を探す。同じモジュールを優先し、無ければソース全体で一意なものを使う。曖昧なら nil
    func lookupType(_ name: String, module: String) -> Int? {
        guard let candidates = typesByName[name], !candidates.isEmpty else { return nil }
        let sameModule = candidates.filter { types[$0].module == module }
        if sameModule.count == 1 { return sameModule[0] }
        if sameModule.isEmpty, candidates.count == 1 { return candidates[0] }
        return nil
    }

    /// typealias をたどって関数型か判定する。探す順は、所有する型 → 外側の型 → ファイル直下。
    /// 同じ段に候補が複数あれば曖昧として関数型とみなさない（構文だけでは決められないため）
    func isFunction(_ ref: TypeRef, owner: String?, module: String, depth: Int = 0) -> Bool {
        if ref.function { return true }
        guard depth < 8, let name = ref.name, let candidates = aliases[name] else { return false }
        var scopes: [String?] = []
        if let owner {
            var parts = owner.split(separator: ".").map(String.init)
            while !parts.isEmpty {
                scopes.append(parts.joined(separator: "."))
                parts.removeLast()
            }
        }
        scopes.append(nil)
        for scope in scopes {
            let inScope = candidates.filter { $0.owner == scope }
            guard !inScope.isEmpty else { continue }
            let sameModule = inScope.filter { $0.module == module }
            let chosen = sameModule.isEmpty ? inScope : sameModule
            guard chosen.count == 1 else { return false }
            return isFunction(chosen[0].target, owner: scope, module: chosen[0].module, depth: depth + 1)
        }
        return false
    }
}
