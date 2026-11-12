import Foundation
import Testing
@testable import CodeEdge

struct UsagePaceTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func forecastsUseShortSingleLineCopy(language: AppLanguage) {
        let cases: [(UsagePace, String, String)] = [
            (pace(delta: 1.3, eta: 84 * 3_600),
             "超前 1.3% · 预计 3 天 12 小时后用尽", "1.3% ahead · runs out in 3d 12h"),
            (pace(delta: 27.9, eta: 31 * 3_600),
             "超前 27.9% · 预计 1 天 7 小时后用尽", "27.9% ahead · runs out in 1d 7h"),
            (pace(delta: 0, eta: nil), "预计撑到重置", "Lasts until reset"),
            (pace(delta: 50, eta: 0, used: 100), "已用完", "Quota depleted"),
        ]
        for (value, chinese, english) in cases {
            let text = paceText(value, now: now, language: language)
            #expect(text == (language == .simplifiedChinese ? chinese : english))
            #expect(!text.contains("\n"))
        }
    }

    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func lessThanAMinuteDoesNotRoundDownToZeroMinutes(language: AppLanguage) {
        let text = paceText(pace(delta: 27.9, eta: 59), now: now, language: language)
        #expect(text == (language == .simplifiedChinese
            ? "超前 27.9% · 预计 1 分钟内用尽"
            : "27.9% ahead · runs out in <1 min"))
        #expect(!text.contains("\n"))
    }

    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func behindOrUnavailableForecastLastsUntilReset(language: AppLanguage) {
        for value in [pace(delta: -4, eta: nil), pace(delta: 1.3, eta: nil)] {
            #expect(paceText(value, now: now, language: language)
                == (language == .simplifiedChinese ? "预计撑到重置" : "Lasts until reset"))
        }
    }

    @Test
    func exactlyOneMinuteKeepsTheCompactDuration() {
        let value = pace(delta: 1.3, eta: 60)
        #expect(paceText(value, now: now, language: .simplifiedChinese) == "超前 1.3% · 预计 1 分钟后用尽")
        #expect(paceText(value, now: now, language: .english) == "1.3% ahead · runs out in 1m")
    }

    private func pace(delta: Double, eta: TimeInterval?, used: Double = 48) -> UsagePace {
        UsagePace(stage: .onTrack, deltaPercent: delta, expectedUsedPercent: used - delta,
                  actualUsedPercent: used, predictionReady: true, etaSeconds: eta,
                  willLastToReset: eta == nil)
    }
}
