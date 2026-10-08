# archlint

[English README](README.md)

`archlint` は、プロジェクト固有の規約を [ast-grep](https://ast-grep.github.io/) の
YAML ルールとして書いておき、コミット前にコードを検査するランナーです。

archlint 自身はルールを持ちません。利用側のリポジトリが ast-grep 標準の
`sgconfig.yml` とルールファイルを持ち、`--config` で archlint に渡します。
archlint は検査対象の決定(たとえば stage された内容だけ)、ast-grep の実行、
診断の表示、pre-commit hook が使える終了コードの返却を担当します。

## インストール

```bash
git clone https://github.com/sei-lit/archlint.git ~/.archlint
ln -s ~/.archlint/bin/archlint /usr/local/bin/archlint
```

依存:

- git
- python3(3.9 以上。macOS の Xcode 付属の python3 で動きます)。標準ライブラリだけを使います
- [ast-grep](https://ast-grep.github.io/guide/quick-start.html#installation)
  (`npm install -g @ast-grep/cli`、`brew install ast-grep`、
  `cargo install ast-grep --locked` のいずれか)

`bin/archlint` は bash 3.2 互換の薄いシムで、python3 を探して `lib/archlint.py` を実行します。

## 使い方

### 1. 利用側のリポジトリにルールを書く

ast-grep のプロジェクトは `sgconfig.yml` とルールファイルです。たとえば `app/` に置く場合:

```yaml
# app/sgconfig.yml
ruleDirs:
  - rules
testConfigs:
  - testDir: rule-tests
```

```yaml
# app/rules/no-japanese-text-literal.yml
id: no-japanese-text-literal
language: swift
severity: error
message: Do not pass a Japanese literal to Text.
note: Use a localized string.
files:
  - Views/**
rule:
  pattern: Text($ARG)
constraints:
  ARG:
    regex: '[ぁ-んァ-ン一-龥]'
```

```yaml
# app/rule-tests/no-japanese-text-literal-test.yml
id: no-japanese-text-literal
valid:
  - Text("hello")
invalid:
  - Text("こんにちは")
```

ルールの `files` / `ignores` は、`sgconfig.yml` があるディレクトリからの相対パスで解決されます。

### 2. コミット前に検査する

```bash
archlint check --config app/sgconfig.yml --staged
```

pre-commit hook の例(`.git/hooks/pre-commit`、または既に使っている hook ランナー):

```bash
#!/bin/bash
exec archlint check --config app/sgconfig.yml --staged --ast-grep-version 0.45.3
```

`--staged` は working tree ではなく git の index の内容を検査します。一部だけ stage した
ファイルも、コミットされる内容で検査されます。archlint は、config のディレクトリ配下で
stage されたファイルと、index にある同ディレクトリ配下の `*.yml` / `*.yaml`(ルールと config)を
一時ディレクトリに書き出し、そこで ast-grep を実行し、終了後にディレクトリを削除します。
そのため、同じコミットに含めるルールの変更もそのコミットの検査に使われます。

出力は診断ごとに 1 行です(行・列は 1 始まり、パスはリポジトリのルートからの相対パス)。

```
app/Views/A.swift:3:9: error[no-japanese-text-literal]: Do not pass a Japanese literal to Text.
  note: Use a localized string.
```

件数の要約は stderr に 1 行出ます。

### 3. 診断を抑制する

ast-grep 標準のコメントを、対象の行の直前か同じ行の末尾に書きます。

```swift
// ast-grep-ignore: no-japanese-text-literal
let v = Text("こんにちは")
```

ルール ID を付けない `// ast-grep-ignore` は、その行のすべてのルールを抑制します。

### 4. ルールをテストする

```bash
archlint test --config app/sgconfig.yml
```

`ast-grep test --skip-snapshot-tests` を実行し、その終了コードを返します。ルールの変更を
検証するため、CI で実行してください。

## コマンド

| コマンド | 内容 |
| --- | --- |
| `archlint check --config <sgconfig.yml> --staged` | config のディレクトリ配下で stage されたファイルの、stage された内容を検査します。該当ファイルが無ければ何も出さず exit 0 です。追加・コピー・変更・リネームされたファイルが対象で、削除されたファイルは対象外です。 |
| `archlint check --config <sgconfig.yml> [paths...]` | working tree を検査します。パスを省略すると config のディレクトリ全体を検査します。 |
| `archlint test --config <sgconfig.yml>` | ルールのテストを実行します。 |
| `archlint doctor` | 使う ast-grep のパスとバージョンを表示します。 |

`--config` は、archlint を実行する git リポジトリ内のファイルでなければなりません。

### オプション

| オプション | 内容 |
| --- | --- |
| `--ast-grep <path>` | ast-grep の実行ファイル。解決順は `--ast-grep`、環境変数 `ARCHLINT_AST_GREP`、PATH 上の `ast-grep` です。 |
| `--ast-grep-version <X.Y.Z>` | ast-grep のバージョンが完全一致することを要求します。環境変数 `ARCHLINT_AST_GREP_VERSION` でも指定できます。一致しなければエラーです。 |

### 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 問題なし。severity が `warning` / `info` / `hint` の診断は表示されますが失敗にはなりません。 |
| 1 | severity が `error` の診断が 1 件以上あります。 |
| 2 | 使い方・環境・ツールの誤り。config が無い、またはリポジトリ外にある、ast-grep が見つからない、またはバージョンが違う、ast-grep が失敗した(たとえばルール YAML が壊れている)、出力を JSON として解析できない、形式が想定と違う、ast-grep 自身の終了コードと食い違う場合です。これらを検査の通過として扱いません。 |

## 制約

- v0.1 は、診断を変更した行だけに絞る機能を持ちません。stage したファイルに既存の違反が
  あると、その変更が違反を作っていなくてもコミットが止まります。違反を直すか、
  `ast-grep-ignore` で抑制してください。
- `--staged` は index の通常ファイルだけを検査します。stage された symlink とサブモジュールの
  エントリ（gitlink）は、index が中身を持たず、symlink を書き出すと ast-grep が working tree の
  内容を読んでしまうため、検査せずに stderr に一覧を出します。
- pre-commit の検査は回避できます（`--no-verify` オプション、hook の未導入、GitHub 上での編集）。
  それらの経路も対象にする必要があるなら、CI でツリー全体に
  `archlint check --config <sgconfig.yml>` を実行してください。

## 開発

```bash
tests/run.sh            # 全テスト(PATH に ast-grep が必要)
tests/run.sh staged     # 名前に "staged" を含むテストだけ
```

CI は macOS と Ubuntu で、ast-grep 0.45.3 を使って shellcheck とテストを実行します。

## ライセンス

MIT
