import Testing
@testable import Yomi

struct DetailTokenFormattingTests {
    @Test
    func zeroDoesNotShowDecimalPlaces() {
        #expect(formatDetailTokensInMillions(0) == "0M")
    }

    @Test
    func valuesBelowOneMillionKeepTwoDecimalPlaces() {
        let samples: [(Int64, String)] = [
            (1, "0.00M"), (4_999, "0.00M"), (5_000, "0.01M"),
            (350_000, "0.35M"), (994_999, "0.99M"),
        ]
        for (tokens, expected) in samples {
            #expect(formatDetailTokensInMillions(tokens) == expected)
        }
    }

    @Test
    func valuesBelowOneHundredMillionKeepOneDecimalPlace() {
        let samples: [(Int64, String)] = [
            (1_000_000, "1.0M"), (1_249_999, "1.2M"), (1_250_000, "1.3M"),
            (12_345_678, "12.3M"), (99_949_999, "99.9M"),
        ]
        for (tokens, expected) in samples {
            #expect(formatDetailTokensInMillions(tokens) == expected)
        }
    }

    @Test
    func largerValuesUseWholeMillionsAndFixedCommaGrouping() {
        let samples: [(Int64, String)] = [
            (100_000_000, "100M"), (100_499_999, "100M"), (100_500_000, "101M"),
            (999_999_999, "1,000M"), (5_812_345_678, "5,812M"),
        ]
        for (tokens, expected) in samples {
            #expect(formatDetailTokensInMillions(tokens) == expected)
        }
    }

    @Test
    func roundingPromotesTheNumberIntoTheNextPrecisionRange() {
        #expect(formatDetailTokensInMillions(995_000) == "1.0M")
        #expect(formatDetailTokensInMillions(999_999) == "1.0M")
        #expect(formatDetailTokensInMillions(99_950_000) == "100M")
        #expect(formatDetailTokensInMillions(99_999_999) == "100M")
    }

    @Test
    func largestTokenCountDoesNotOverflowWhileRounding() {
        #expect(formatDetailTokensInMillions(.max) == "9,223,372,036,855M")
    }
}
