# archlint

[日本語の README](README.ja.md)

`archlint` checks project-specific Swift conventions, written as YAML rules, before you commit.

[ast-grep](https://ast-grep.github.io/) only sees the syntax tree of one file at a time. archlint uses [SwiftSyntax](https://github.com/swiftlang/swift-syntax) to collect *facts* (types, members, calls, typealiases) from every file, so YAML rules can express checks such as:

- a type that becomes a `View` through `extension A: View {}` in another file
- a property whose type is `typealias Handler = () -> Void` declared in another file
- a string put in `let title = "..."` inside a function and then passed to `Text(title)`
- nested conditional compilation, including an `#if` inside `#if DEBUG`

It reads syntax only and never builds, so a pre-commit check of 3,900 files takes 2–3 seconds. The trade-off: inferred types and declarations that are not in the sources (SDKs and so on) are unknown.

Rules that only need one file can stay ast-grep rules; archlint runs them from the same command.

## Installation

Requires Swift 6.4 (Xcode 27) or later.

```bash
git clone https://github.com/sei-lit/archlint.git
cd archlint
swift build -c release
# .build/release/archlint
```

The first build compiles swift-syntax and takes 2–3 minutes. In a consuming repository, pin a tag and its commit SHA, build once, and cache the binary.

## Configuration: `archlint.yml`

All paths are relative to the directory that contains this file.

```yaml
version: 1
sources:                     # files to collect facts from (the scope of cross-file checks)
  - Sources/**
ignores:
  - Sources/**/Generated/**
module: '^Sources/(?<module>[^/]+)/'   # optional; tells same-named types in different modules apart
rules: lint/rules            # directory of rules (*.yml)
tests: lint/rule-tests       # optional; rule tests
baseline: lint/baseline.json # optional; violations that existed when the rules were introduced
astGrep:                     # optional; also run ast-grep rules
  config: sgconfig.yml
```

## Rules

```yaml
id: closure-view-must-be-auto-equatable
severity: warning            # error (default) or warning
message: Views holding closures must be @AutoEquatable
note: See docs/views.md      # optional
files: [Sources/Features/**] # optional; limits where diagnostics are reported
ignores: []                  # optional
select:                      # what to check: exactly one of type / member / call
  type:
    kind: struct
    inherits: View
    has:
      member: { stored: true, type: { function: true } }
    not:
      has:
        member: { attribute: [StateObject, ObservedObject, Binding] }
require:                     # optional; what a selected entity must satisfy. Without it, every selected entity is a violation
  attribute: AutoEquatable
  inherits: EquatableBodyView
```

### Conditions

- Values: a string matches exactly, `/.../` is a regular expression, and a list matches any of its items
- All conditions in one mapping must hold. Combine them with `all` / `any` / `not`
- An unknown key is a configuration error (exit status 2), so a typo cannot silently drop a condition and let everything pass

| Entity | Keys |
|---|---|
| any | `all` `any` `not`, `file` (glob), `module`, `preview` (inside `#Preview` / a `PreviewProvider`), `condition` (an enclosing `#if` condition; the `#else` branch is `!DEBUG`) |
| `type` | `kind` (struct / class / enum / actor / protocol), `name`, `qualifiedName` (`Outer.Inner`), `attribute`, `inherits` (including conformances added by extensions in any file), `has: { member: … }` / `has: { call: … }` |
| `member` | `kind` (func / var / let / init / subscript), `name`, `declaredIn` (type / extension / file), `owner` (the owning type, or the extended type), `static`, `stored`, `type`, `returns` (a function's return type, or a computed property's type), `attribute`, `modifier`, `parameter: { label, name, type }`, `in: { type: … }` |
| `call` | `callee` (`Text`; `navigationTitle` for `x.navigationTitle`), `calleeText`, `argument: { label, kind, value, text }`, `in: { type: …, member: … }` |
| type references (`type` / `returns` / a parameter's `type`) | `name`, `text`, `opaque` (`View` for `some View`), `function` (a function type after resolving typealiases), `optional`, `not`, `any` |

`argument.kind` is `string` (a string literal without interpolation, including one bound by `let x = "..."` earlier in the same function), `interpolation`, `identifier`, `closure` or `other`. `value` is the literal's text without its interpolated parts. An unlabeled argument has the label `_`.

Typealiases are looked up in the owning type, then its enclosing types, then at file level. If one level has more than one candidate, the alias is ambiguous and is left unresolved.

Run `archlint facts <file.swift>` to see the facts a rule can use.

### Suppressing a diagnostic

Put the rule ID and the reason in the comment right before the declaration or call:

```swift
// archlint-ignore: closure-view-must-be-auto-equatable wraps a view from an external SDK
struct SDKWrapperView: View { … }
```

## Rule tests

```yaml
id: closure-view-must-be-auto-equatable
valid:
  - '@AutoEquatable struct A: EquatableBodyView, View { let onTap: () -> Void; var equatableBody: some View { EmptyView() } }'
invalid:
  - files:                   # a cross-file case is a set of files
      Handler.swift: typealias Handler = () -> Void
      A.swift: 'struct A: View { let onTap: Handler; var body: some View { EmptyView() } }'
```

Run them with `archlint test --config archlint.yml` (this also runs the ast-grep rule tests).

## Checking before a commit

```bash
archlint check --staged --config app/archlint.yml
```

- It checks the content of the git index, which is what will be committed. Unstaged edits are ignored. The configuration, rules and baseline are read from the index too
- A cross-file rule can make an unchanged file violate (for example, when a typealias becomes a function type). So archlint evaluates both the index and HEAD with the same rules and reports **violations added since HEAD**, wherever they are, not only in staged files
- Violations already in HEAD or in the baseline do not block the commit
- A file with syntax errors yields incomplete facts, so a syntax error in a staged file stops the check with exit status 2
- ast-grep rules check only the staged files, because they are confined to one file

Use the exit status in a pre-commit hook: 0 no problems, 1 error-severity violations, 2 environment, configuration or usage error.

Without `--staged`, `check` scans the whole working tree and reports violations that are not in the baseline (for CI, when rules change).

## Baseline

```bash
archlint baseline --config app/archlint.yml          # record every current violation (when introducing rules)
archlint baseline --prune --config app/archlint.yml  # only lower the counts of fixed violations
```

The baseline counts violations per rule + file + symbol (type, member, argument labels, callee). It has no line numbers, so moving code does not create new violations. Renaming a file changes the key; regenerate the baseline after a rename.

When a fix makes a count drop below the baseline, `check` fails until you run `--prune`. Keeping the old count would let the same violation come back unnoticed.

## ast-grep

With `astGrep.config`, `check` and `test` also run ast-grep. The executable is taken from `--ast-grep <path>`, then `ARCHLINT_AST_GREP`, then `PATH`. `--ast-grep-version 0.45.3` refuses any other version. Suppress ast-grep diagnostics with ast-grep's own `// ast-grep-ignore: <id>`.

## Out of scope

- Checks that need type inference or build products (the index store)
- Languages other than Swift
- Arbitrary scripts inside rules. A check that YAML conditions cannot express is handled by extracting a new kind of fact

## License

MIT
