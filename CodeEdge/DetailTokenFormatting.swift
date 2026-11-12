import Foundation

nonisolated func formatDetailTokensInMillions(_ tokens: Int64) -> String {
    guard tokens > 0 else { return "0M" }

    func roundedUnits(divisor: Int64) -> Int64 {
        tokens / divisor + (tokens % divisor >= divisor / 2 ? 1 : 0)
    }

    let hundredths = roundedUnits(divisor: 10_000)
    if hundredths < 100 {
        let decimal = String(hundredths % 100)
        return "0.\(decimal.count == 1 ? "0" : "")\(decimal)M"
    }

    let tenths = roundedUnits(divisor: 100_000)
    if tenths < 1_000 {
        return "\(tenths / 10).\(tenths % 10)M"
    }

    let millions = roundedUnits(divisor: 1_000_000)
    return millions.formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic)) + "M"
}
