import Foundation
import Testing
@testable import CodeEdge

struct CompactTokenCountTests {
    @Test(arguments: [
        (Int64(0), "0"),
        (999, "999"),
        (1_000, "1.0K"),
        (9_999, "10.0K"),
        (12_345, "12.3K"),
        (99_949, "99.9K"),
        (99_950, "100K"),
        (100_000, "100K"),
        (123_456, "123K"),
        (580_000, "580K"),
        (999_499, "999K"),
        (999_500, "1.0M"),
        (999_950, "1.0M"),
        (1_000_000, "1.0M"),
        (1_234_567, "1.2M"),
        (9_994_999, "10.0M"),
        (9_999_500, "10.0M"),
        (59_640_000, "59.6M"),
        (99_949_999, "99.9M"),
        (99_950_000, "100M"),
        (99_994_999, "100M"),
        (99_995_000, "100M"),
        (123_000_000, "123M"),
        (580_000_000, "580M"),
        (999_499_999, "999M"),
        (999_500_000, "1.0B"),
        (999_950_000, "1.0B"),
        (1_050_000_000, "1.1B"),
        (100_000_000_000, "100B"),
    ])
    func formatsWithEnglishUnitsAndCarriesRoundedBoundaries(value: Int64, expected: String) {
        #expect(compactTokenCount(value) == expected)
    }

    @Test(arguments: [Int64(-1), -999, -1_234_567, .min])
    func negativeValuesKeepTheExistingGroupedIntegerFormat(value: Int64) {
        #expect(compactTokenCount(value) == value.formatted(.number.grouping(.automatic)))
    }
}
