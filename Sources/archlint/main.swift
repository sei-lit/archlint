import ArchlintCore
import Foundation

let usage = """
usage: archlint <command> [options]

commands:
  check     規約を検査する（--staged: git の index の内容を検査し、HEAD から増えた違反だけを止める）
  test      ルールのテストを実行する
  baseline  今ある違反を baseline に書く（--prune: 直った分だけ減らす）
  facts     Swift ファイルから抽出した事実を JSON で出す（ルールを書くとき用）
  doctor    設定・ツールの状態を表示する

options:
  --config <path>            archlint.yml（既定: ./archlint.yml）
  --staged                   check で index の内容を検査する
  --prune                    baseline で件数を減らすだけにする
  --ast-grep <path>          ast-grep の実行ファイル（既定: $ARCHLINT_AST_GREP か PATH の ast-grep）
  --ast-grep-version <ver>   このバージョンの ast-grep だけを使う（既定: $ARCHLINT_AST_GREP_VERSION）
  --version

exit status: 0 問題なし / 1 error の違反あり / 2 環境・設定・使い方の誤り
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("archlint: \(message)\n".utf8))
    exit(ExitCode.toolError.rawValue)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--version" {
    print("archlint \(Commands.version)")
    exit(0)
}
guard let command = arguments.first, !command.hasPrefix("-") else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(ExitCode.toolError.rawValue)
}
arguments.removeFirst()

var options = Options()
var remaining = arguments.makeIterator()
while let argument = remaining.next() {
    func value() -> String {
        guard let value = remaining.next() else { fail("\(argument) に値が要る") }
        return value
    }
    switch argument {
    case "--config": options.config = value()
    case "--staged": options.staged = true
    case "--prune": options.prune = true
    case "--ast-grep": options.astGrep = value()
    case "--ast-grep-version": options.astGrepVersion = value()
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") { fail("知らないオプション: \(argument)") }
        options.paths.append(argument)
    }
}

do {
    let result: ExitCode
    switch command {
    case "check": result = try Commands.check(options)
    case "test": result = try Commands.test(options)
    case "baseline": result = try Commands.baseline(options)
    case "facts": result = try Commands.facts(options)
    case "doctor": result = try Commands.doctor(options)
    default: fail("知らないコマンド: \(command)")
    }
    exit(result.rawValue)
} catch let error as ToolError {
    fail(error.description)
} catch {
    fail("\(error)")
}
