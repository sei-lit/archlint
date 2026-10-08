# archlint

[日本語 README](README.ja.md)

`archlint` runs project-specific conventions, written as [ast-grep](https://ast-grep.github.io/)
YAML rules, against your code before each commit.

archlint ships no rules. The repository that uses it keeps a standard ast-grep
`sgconfig.yml` and the rule files, and passes the config to archlint with
`--config`. archlint decides what to scan (for example, only the staged content),
runs ast-grep, prints the diagnostics, and returns an exit code a pre-commit hook
can act on.

## Install

```bash
git clone https://github.com/sei-lit/archlint.git ~/.archlint
ln -s ~/.archlint/bin/archlint /usr/local/bin/archlint
```

Requirements:

- git
- python3, 3.9 or later (the python3 that ships with Xcode on macOS works). Only
  the standard library is used.
- [ast-grep](https://ast-grep.github.io/guide/quick-start.html#installation)
  (`npm install -g @ast-grep/cli`, `brew install ast-grep`, or
  `cargo install ast-grep --locked`)

`bin/archlint` is a small bash 3.2 compatible shim that finds python3 and runs
`lib/archlint.py`.

## Usage

### 1. Describe the rules in your repository

An ast-grep project is a `sgconfig.yml` plus rule files. For example, in `app/`:

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

The `files` and `ignores` fields of a rule are resolved relative to the directory
that holds `sgconfig.yml`.

### 2. Check before committing

```bash
archlint check --config app/sgconfig.yml --staged
```

Example pre-commit hook (`.git/hooks/pre-commit`, or the hook runner you already use):

```bash
#!/bin/bash
exec archlint check --config app/sgconfig.yml --staged --ast-grep-version 0.45.3
```

`--staged` checks the content in the git index, not the working tree, so a
partially staged file is checked as it will be committed. archlint exports the
staged files under the config directory, plus the `*.yml` / `*.yaml` files in that
directory from the index (the rules and the config), to a temporary directory,
runs ast-grep there, and removes the directory afterwards. A rule change that you
are committing is therefore applied in the same commit.

Output, one line per diagnostic (line and column start at 1, the path is relative
to the repository root):

```
app/Views/A.swift:3:9: error[no-japanese-text-literal]: Do not pass a Japanese literal to Text.
  note: Use a localized string.
```

A one-line summary goes to stderr.

### 3. Suppress a diagnostic

Use ast-grep's own comment, on the line above the code or at the end of the same line:

```swift
// ast-grep-ignore: no-japanese-text-literal
let v = Text("こんにちは")
```

`// ast-grep-ignore` without a rule id suppresses every rule on that line.

### 4. Test the rules

```bash
archlint test --config app/sgconfig.yml
```

Runs `ast-grep test --skip-snapshot-tests` and returns its exit code. Run it in CI
so that rule changes are verified.

## Commands

| Command | What it does |
| --- | --- |
| `archlint check --config <sgconfig.yml> --staged` | Scans the staged content of files under the config directory. Exits 0 without output when none of them is staged. Added, copied, modified and renamed files are scanned; deleted files are not. |
| `archlint check --config <sgconfig.yml> [paths...]` | Scans the working tree. Without paths, scans the whole config directory. |
| `archlint test --config <sgconfig.yml>` | Runs the rule tests. |
| `archlint doctor` | Prints the path and version of the ast-grep in use. |

`--config` must point to a file inside the git repository that you run archlint in.

### Options

| Option | Meaning |
| --- | --- |
| `--ast-grep <path>` | ast-grep executable. Resolution order: `--ast-grep`, then `ARCHLINT_AST_GREP`, then `ast-grep` on PATH. |
| `--ast-grep-version <X.Y.Z>` | Require exactly this ast-grep version. Also settable with `ARCHLINT_AST_GREP_VERSION`. A different version is an error. |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | No problems. Diagnostics with severity `warning`, `info` or `hint` are printed but do not fail. |
| 1 | At least one diagnostic with severity `error`. |
| 2 | Usage, environment or tool error: missing or out-of-repository config, ast-grep not found or of a different version, ast-grep failed (for example, a rule YAML is broken), or its output could not be parsed as JSON. archlint does not treat these as a pass. |

## Limitations

- v0.1 cannot restrict diagnostics to the changed lines. If a staged file already
  contains a violation, the commit is stopped even when the change did not
  introduce it. Fix the violation, or suppress it with `ast-grep-ignore`.
- `--staged` passes the target files as command-line arguments, so a commit with
  a very large number of files can exceed the operating system's argument length
  limit.
- Submodule entries are not handled specially.

## Development

```bash
tests/run.sh            # all tests; requires ast-grep on PATH
tests/run.sh staged     # tests whose name contains "staged"
```

CI runs shellcheck and the tests on macOS and Ubuntu with ast-grep 0.45.3.

## License

MIT
