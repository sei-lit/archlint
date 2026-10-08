import Foundation

/// 1 ファイルで判定できるルールは ast-grep のまま使う。archlint は対象を決めて実行し、結果を同じ形式で出す
struct AstGrep {
    let executable: String

    static func resolve(_ explicit: String?, requiredVersion: String?) throws -> AstGrep {
        let executable = explicit ?? ProcessInfo.processInfo.environment["ARCHLINT_AST_GREP"] ?? "ast-grep"
        let tool = AstGrep(executable: executable)
        if let requiredVersion = requiredVersion ?? ProcessInfo.processInfo.environment["ARCHLINT_AST_GREP_VERSION"] {
            let actual = try tool.version()
            guard actual.split(separator: " ").last.map(String.init) == requiredVersion else {
                throw ToolError("ast-grep のバージョンが違う: 必要 \(requiredVersion)、実際 \(actual)（\(executable)）")
            }
        }
        return tool
    }

    func version() throws -> String {
        let result = try Shell.run(executable, ["--version"])
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !text.isEmpty else {
            throw ToolError("\(executable) --version が失敗した: \(result.stderrText)")
        }
        return text
    }

    /// 引数で対象を渡すので、大きなコミットで OS の引数の上限を超えないよう分けて渡す
    static let chunk = 200

    /// `targets` が空なら設定の files に従って全体を走査する
    func scan(config: String, targets: [String], cwd: String) throws -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let chunks = targets.isEmpty ? [[]] : stride(from: 0, to: targets.count, by: Self.chunk).map {
            Array(targets[$0..<min($0 + Self.chunk, targets.count)])
        }
        for chunk in chunks {
            let result = try Shell.run(executable, ["scan", "--config", config, "--json=compact"] + chunk, cwd: cwd)
            diagnostics.append(contentsOf: try parse(result, cwd: cwd))
        }
        return diagnostics
    }

    func test(config: String, cwd: String) throws -> Bool {
        let result = try Shell.run(executable, ["test", "--config", config, "--skip-snapshot-tests"], cwd: cwd)
        FileHandle.standardOutput.write(result.stdout)
        FileHandle.standardError.write(result.stderr)
        return result.status == 0
    }

    private func parse(_ result: ProcessResult, cwd: String) throws -> [Diagnostic] {
        guard result.status == 0 || result.status == 1 else {
            throw ToolError("ast-grep が終了コード \(result.status) で終わった: \(result.stderrText)")
        }
        guard let items = try? JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else {
            throw ToolError("ast-grep の出力が JSON の配列ではない。検査を通さずに止める: \(result.stderrText)")
        }
        var diagnostics: [Diagnostic] = []
        for item in items {
            guard let file = item["file"] as? String,
                  let range = item["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int else {
                throw ToolError("ast-grep の診断の形式が想定と違う。検査を通さずに止める")
            }
            let rule = item["ruleId"] as? String ?? ""
            let severity: Severity? = switch item["severity"] as? String {
            case "error": .error
            case "warning": .warning
            default: nil
            }
            guard let severity else { continue }
            let path = file.hasPrefix("/") ? file : Paths.join(cwd, file)
            diagnostics.append(Diagnostic(
                rule: rule,
                severity: severity,
                message: item["message"] as? String ?? "",
                note: item["note"] as? String,
                file: Paths.normalize(path),
                line: line + 1,
                key: "\(rule) | \(file) | ast-grep"
            ))
        }
        // ast-grep は error の診断があるときだけ終了コード 1 を返す。食い違うなら出力を信用できない
        let hasError = items.contains { $0["severity"] as? String == "error" }
        guard hasError == (result.status == 1) else {
            throw ToolError("ast-grep の終了コード \(result.status) と診断が食い違う。検査を通さずに止める")
        }
        return diagnostics
    }
}
