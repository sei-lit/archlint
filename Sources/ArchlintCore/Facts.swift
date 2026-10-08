/// 1 ファイルの構文から抽出する事実。ルールはこの事実に対する条件だけで書く。
/// 推論された型は持たない（ビルドせずに pre-commit で動かすため）。

public struct SourceContext: Codable, Hashable, Sendable {
    /// `#Preview` の中、または `PreviewProvider` に準拠する型の中
    public var preview: Bool
    /// 囲む `#if` の条件。`#else` 側は前の条件の否定（`!DEBUG`）として持つ
    public var conditions: [String]

    public static let root = SourceContext(preview: false, conditions: [])
}

public struct TypeRef: Codable, Hashable, Sendable {
    public var text: String
    /// 単純な型名（`Foo.Bar<Baz>?` なら `Bar`）。関数型・タプルなどは nil
    public var name: String?
    /// `some P` の `P`
    public var opaque: String?
    /// 書かれた形が関数型か（typealias の解決は FactSet が行う）
    public var function: Bool
    public var optional: Bool
}

public struct Parameter: Codable, Hashable, Sendable {
    /// 呼び出し側のラベル。ラベルなしは `_`
    public var label: String
    public var name: String
    public var type: TypeRef?
}

public enum TypeKind: String, Codable, Sendable {
    case `struct`, `class`, `enum`, actor, `protocol`
}

public struct TypeFact: Codable, Hashable, Sendable {
    public var kind: TypeKind
    public var name: String
    public var qualifiedName: String
    public var attributes: [String]
    /// 型の宣言に書いた準拠・継承。extension での準拠は FactSet が合わせる
    public var inherits: [String]
    public var file: String
    public var line: Int
    public var context: SourceContext
    public var ignores: [String]
}

public struct ExtensionFact: Codable, Hashable, Sendable {
    public var extendedType: String
    public var inherits: [String]
    public var file: String
    public var line: Int
    public var context: SourceContext
}

public enum MemberKind: String, Codable, Sendable {
    case `func`, `var`, `let`, `init`, `subscript`
}

public enum DeclaredIn: String, Codable, Sendable {
    case type, `extension`, file
}

public struct MemberFact: Codable, Hashable, Sendable {
    public var kind: MemberKind
    public var name: String
    public var declaredIn: DeclaredIn
    /// 所有する型の名前（型の中なら修飾名、extension なら書かれた拡張先）。ファイル直下は nil
    public var owner: String?
    public var isStatic: Bool
    /// stored property か（`let` / アクセサなし / willSet・didSet だけの `var`）
    public var stored: Bool
    /// プロパティの型
    public var type: TypeRef?
    /// 関数の戻り値の型。computed property ではプロパティの型
    public var returns: TypeRef?
    public var attributes: [String]
    public var modifiers: [String]
    public var parameters: [Parameter]
    public var file: String
    public var line: Int
    public var context: SourceContext
    public var ignores: [String]
}

public enum ArgumentKind: String, Codable, Sendable {
    /// 文字列リテラル（補間なし）。関数内の `let x = "..."` を渡した場合も含む
    case string
    /// 補間を含む文字列リテラル
    case interpolation
    case identifier
    case closure
    case other
}

public struct Argument: Codable, Hashable, Sendable {
    public var label: String
    public var kind: ArgumentKind
    /// 文字列リテラルの中身。補間を含む場合は補間以外の部分をつないだもの
    public var value: String?
    public var text: String
}

public struct CallFact: Codable, Hashable, Sendable {
    /// 呼び出す名前の最後の部分（`Text`、`foo.navigationTitle` なら `navigationTitle`）
    public var callee: String
    public var calleeText: String
    public var arguments: [Argument]
    /// 囲む型（extension の中なら拡張先）
    public var ownerType: String?
    /// 囲むメンバー（関数・プロパティ・init）の名前
    public var ownerMember: String?
    /// 囲むメンバーの引数ラベル（`(title:action:)`）。同名の overload を区別する
    public var ownerSignature: String?
    public var file: String
    public var line: Int
    public var context: SourceContext
    public var ignores: [String]
}

public struct TypeAliasFact: Codable, Hashable, Sendable {
    public var name: String
    /// 型の中で宣言した場合はその型の修飾名
    public var owner: String?
    public var target: TypeRef
    public var file: String
}

public struct FileFacts: Codable, Sendable {
    public var path: String
    public var module: String
    public var types: [TypeFact] = []
    public var extensions: [ExtensionFact] = []
    public var members: [MemberFact] = []
    public var calls: [CallFact] = []
    public var typeAliases: [TypeAliasFact] = []
    /// 構文エラーの位置（行）。空でなければ事実は信用できない
    public var syntaxErrors: [Int] = []

    public init(path: String, module: String) {
        self.path = path
        self.module = module
    }
}
