import Foundation

/// 導入時点で既にある違反。キーごとの件数で持ち、件数を超えた分を新しい違反とする。
/// 違反を直して件数が減ったら baseline も減らす（stale のまま残すと、同じ場所での再発を通してしまうため）
public struct Baseline: Equatable {
    static let version = 1

    public var counts: [String: Int] = [:]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    init(_ diagnostics: [Diagnostic]) {
        for diagnostic in diagnostics { counts[diagnostic.key, default: 0] += 1 }
    }

    static func parse(_ data: Data, source: String) throws -> Baseline {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, let entries = object["entries"] as? [String: Int] else {
            throw ToolError("\(source): baseline の形式が違う（archlint baseline で作り直す）")
        }
        guard version == Self.version else {
            throw ToolError("\(source): baseline の version \(version) は読めない（この archlint は \(Self.version)）")
        }
        return Baseline(counts: entries)
    }

    func serialized() throws -> Data {
        let object: [String: Any] = ["version": Self.version, "entries": counts]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(10)
        return data
    }

    /// baseline にあるが、今は件数が足りないキー
    func stale(against diagnostics: [Diagnostic]) -> [(key: String, expected: Int, actual: Int)] {
        let actual = Baseline(diagnostics).counts
        return counts.compactMap { key, expected in
            let found = actual[key] ?? 0
            return found < expected ? (key, expected, found) : nil
        }.sorted { $0.key < $1.key }
    }

    /// 今の件数を超えない範囲に減らす（増やさない）
    func pruned(against diagnostics: [Diagnostic]) -> Baseline {
        let actual = Baseline(diagnostics).counts
        var result = Baseline()
        for (key, expected) in counts {
            let kept = min(expected, actual[key] ?? 0)
            if kept > 0 { result.counts[key] = kept }
        }
        return result
    }
}

enum NewDiagnostics {
    /// 許される件数（HEAD にあった件数と baseline の件数の大きい方）を超えたキーの診断を返す
    static func select(_ diagnostics: [Diagnostic], head: [Diagnostic]?, baseline: Baseline) -> [Diagnostic] {
        let current = Baseline(diagnostics).counts
        let before = head.map { Baseline($0).counts } ?? [:]
        let exceeded = Set(current.compactMap { key, count in
            count > max(before[key] ?? 0, baseline.counts[key] ?? 0) ? key : nil
        })
        return diagnostics.filter { exceeded.contains($0.key) }
    }
}
