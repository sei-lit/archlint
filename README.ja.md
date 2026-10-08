# archlint

[English README](README.md)

`archlint` は、Swift プロジェクト固有の規約を YAML のルールとして書き、コミット前に検査するツールです。

[ast-grep](https://ast-grep.github.io/) は 1 ファイルの構文木しか見られません。archlint は [SwiftSyntax](https://github.com/swiftlang/swift-syntax) で全ファイルから「事実」（型・メンバー・呼び出し・typealias）を集め、次のような判定を YAML で書けるようにします。

- 別ファイルの `extension A: View {}` で View になった型
- 別ファイルの `typealias Handler = () -> Void` を型に持つプロパティ
- 関数の中で `let title = "..."` に入れてから `Text(title)` に渡した文言
- `#if DEBUG` の中の `#if` を含む、条件付きコンパイルの入れ子

ビルドせずに構文だけを見るので、pre-commit で 3,900 ファイルを 2〜3 秒で検査できます。その代わり、推論された型や、ソースに無い定義（SDK など）は分かりません。

1 ファイルで判定できるルールは ast-grep のまま書けます。archlint は ast-grep のルールも同じコマンドで実行します。

## インストール

Swift 6.4（Xcode 27）以上が要ります。

```bash
git clone https://github.com/sei-lit/archlint.git
cd archlint
swift build -c release
# .build/release/archlint
```

初回のビルドは swift-syntax を含むため 2〜3 分かかります。利用側のリポジトリでは、タグとコミット SHA を固定して一度だけビルドし、キャッシュしてください。

## 設定 `archlint.yml`

パスはすべて、このファイルのあるディレクトリからの相対パスです。

```yaml
version: 1
sources:                     # 事実を集めるファイル（ファイルをまたぐ判定の対象範囲）
  - Sources/**
ignores:
  - Sources/**/Generated/**
module: '^Sources/(?<module>[^/]+)/'   # 任意。モジュールが違う同名の型を区別する
rules: lint/rules            # ルール（*.yml）のディレクトリ
tests: lint/rule-tests       # 任意。ルールのテスト
baseline: lint/baseline.json # 任意。導入時点の違反
astGrep:                     # 任意。ast-grep のルールも一緒に実行する
  config: sgconfig.yml
```

## ルール

```yaml
id: closure-view-must-be-auto-equatable
severity: warning            # error（既定）/ warning
message: クロージャを持つ View は @AutoEquatable にする
note: docs/views.md を参照    # 任意
files: [Sources/Features/**] # 任意。診断を出すファイルを絞る
ignores: []                  # 任意
select:                      # 対象。type / member / call のどれか 1 つ
  type:
    kind: struct
    inherits: View
    has:
      member: { stored: true, type: { function: true } }
    not:
      has:
        member: { attribute: [StateObject, ObservedObject, Binding] }
require:                     # 任意。対象が満たすべき条件。省略すると対象そのものが違反
  attribute: AutoEquatable
  inherits: EquatableBodyView
```

### 条件の書き方

- 値: 文字列は完全一致、`/.../` で囲むと正規表現、配列はいずれかに一致
- 同じ mapping に書いた条件はすべて満たす必要がある。`all` / `any` / `not` で組み合わせる
- 知らないキーは設定の誤りとして終了コード 2（書き間違いで条件が消え、全件が通るのを防ぐ）

| 対象 | キー |
|---|---|
| 共通 | `all` `any` `not`、`file`（glob）、`module`、`preview`（`#Preview` / `PreviewProvider` の中か）、`condition`（囲む `#if` の条件。`#else` 側は `!DEBUG`） |
| `type` | `kind`（struct / class / enum / actor / protocol）、`name`、`qualifiedName`（`Outer.Inner`）、`attribute`、`inherits`（全ファイルの extension での準拠を含む）、`has: { member: … }` / `has: { call: … }` |
| `member` | `kind`（func / var / let / init / subscript）、`name`、`declaredIn`（type / extension / file）、`owner`（所有する型。extension なら拡張先）、`static`、`stored`、`type`、`returns`（関数の戻り値。computed property はその型）、`attribute`、`modifier`、`parameter: { label, name, type }`、`in: { type: … }` |
| `call` | `callee`（`Text`、`x.navigationTitle` なら `navigationTitle`）、`calleeText`、`argument: { label, kind, value, text }`、`in: { type: …, member: … }` |
| 型（`type` / `returns` / 引数の `type`） | `name`、`text`、`opaque`（`some View` なら `View`）、`function`（typealias を解決した後で関数型か）、`optional`、`not`、`any` |

`argument.kind` は `string`（補間なしの文字列リテラル。同じ関数内の `let x = "..."` を渡した場合を含む）/ `interpolation` / `identifier` / `closure` / `other`。`value` は文字列リテラルの中身（補間の部分を除く）です。引数ラベルが無い場合、`label` は `_` です。

typealias は、所有する型 → 外側の型 → ファイル直下の順に探します。同じ段に候補が複数あれば曖昧とみなし、解決しません。

ルールで使える事実は `archlint facts <file.swift>` で確かめられます。

### 例外にする

対象の宣言・呼び出しの直前のコメント（空行を挟まない）に、ルール ID と理由を書きます。複数のルールはカンマで区切ります（`archlint-ignore: rule-a,rule-b 理由`）。最初の語の後ろはすべて理由として読みます。

```swift
// archlint-ignore: closure-view-must-be-auto-equatable 外部 SDK の View を包むため
struct SDKWrapperView: View { … }
```

## ルールのテスト

```yaml
id: closure-view-must-be-auto-equatable
valid:
  - '@AutoEquatable struct A: EquatableBodyView, View { let onTap: () -> Void; var equatableBody: some View { EmptyView() } }'
invalid:
  - files:                   # ファイルをまたぐ例はファイルの組で書く
      Handler.swift: typealias Handler = () -> Void
      A.swift: 'struct A: View { let onTap: Handler; var body: some View { EmptyView() } }'
```

`archlint test --config archlint.yml` で実行します（ast-grep のルールのテストも実行します）。

## コミット前の検査

```bash
archlint check --staged --config app/archlint.yml
```

- git の index の内容（コミットされる内容）を検査します。stage していない編集は見ません。設定・ルール・baseline も index から読みます
- ファイルをまたぐ判定では、変えていないファイルが違反になることがあります（typealias を関数型に変えたなど）。そのため index と HEAD の両方を同じルールで評価し、**HEAD から増えた違反**を報告します。報告する場所は stage したファイルに限りません
- HEAD に既にある違反と baseline の違反ではコミットを止めません
- 構文エラーのあるファイルは事実が欠けるので、対象のファイルのどれかに構文エラーがあれば終了コード 2 で止めます（変えていないファイルも含みます。ファイルをまたぐ判定にそのファイルの事実が要るため）
- ast-grep のルールは stage したファイルだけを検査します（1 ファイルで完結するため）

pre-commit hook からは、終了コードで判定してください: 0 問題なし / 1 error の違反あり / 2 環境・設定・使い方の誤り。

`--staged` なしの `check` は working tree の全体を検査し、baseline にない違反を報告します（CI でルールを変えたときの確認用）。

## baseline

```bash
archlint baseline --config app/archlint.yml          # 今ある違反をすべて書く（導入時）
archlint baseline --prune --config app/archlint.yml  # 直った分だけ減らす
```

違反の件数を「ルール + ファイル + シンボル（型・メンバー・引数ラベル・呼び出す名前）」ごとに持ちます。行番号は使わないので、行が動いても新しい違反にはなりません。ファイルの名前を変えると別のキーになるので、baseline を書き直してください。

違反を直して件数が baseline より減ると、`--prune` で baseline を減らすまで `check` が止まります。減った分を残すと、同じ場所での再発を通してしまうためです。

## ast-grep

`astGrep.config` を書くと、`check` と `test` で ast-grep も実行します。ast-grep の実行ファイルは `--ast-grep <path>` か環境変数 `ARCHLINT_AST_GREP`、無ければ PATH から探します。`--ast-grep-version 0.45.3` を付けると、違う版では実行しません。ast-grep のルールの例外は ast-grep の `// ast-grep-ignore: <id>` で書きます。

## 作らないもの

- 型推論やビルド成果物（index store）を使う判定
- Swift 以外の言語
- ルールの中に任意のスクリプトを書く仕組み。YAML の条件で書けない判定は、抽出する事実の種類を増やして対応します

## ライセンス

MIT
