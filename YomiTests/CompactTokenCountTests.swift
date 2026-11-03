import Testing
@testable import Yomi

struct CompactTokenCountTests {
    @Test(arguments: [
        (Int64(9_999), "9,999"),
        (12_345, "1.2万"),
        (1_234_567, "123.5万"),
        (9_994_999, "999.5万"),
        (9_999_500, "1000万"),
        (59_640_000, "5964万"),
        (99_994_999, "9999万"),
        (99_995_000, "1.0亿"),
        (1_050_000_000, "10.5亿"),
    ])
    func chineseDropsDecimalsOnceFourDigitsAreShown(value: Int64, expected: String) {
        #expect(compactTokenCount(value, language: .simplifiedChinese) == expected)
    }

    @Test
    func englishFormatIsUnchanged() {
        #expect(compactTokenCount(59_640_000, language: .english) == "59.6M")
        #expect(compactTokenCount(1_050_000_000, language: .english) == "1.1B")
    }
}
