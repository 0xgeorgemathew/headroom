import Testing
@testable import HeadroomKit

@Suite("Number formatting")
struct NumberFormatTests {
    /// Strings from the Activity mockup's stat tiles and heroes.
    @Test(arguments: [
        (Int64(189_000_000), "189M"),
        (5_600_000, "5.6M"),
        (1_090_000, "1.09M"),
        (182_000_000, "182M"),
        (8_110_000, "8.11M"),
        (247_000_000, "247M"),
        (257_000_000, "257M"),
        (12_300, "12.3K"),
        (940, "940"),
        (0, "0"),
        (1_000, "1K"),
        (1_400_000, "1.4M"),
        (69_400_000, "69.4M"),
        (999_600, "1M"),
        (1_234_000_000, "1.23B"),
        (189_440_000, "189M"),
    ])
    func tokens(count: Int64, expected: String) {
        #expect(NumberFormat.tokens(count) == expected)
    }

    @Test(arguments: [
        (104.70, "$104.70"),
        (66.10, "$66.10"),
        (36.90, "$36.90"),
        (1.70, "$1.70"),
        (49.80, "$49.80"),
        (21.50, "$21.50"),
        (12_400, "$12.4K"),
        (0, "$0"),
        (0.001, "<$0.01"),
    ])
    func preciseDollars(usd: Double, expected: String) {
        #expect(NumberFormat.dollars(usd, style: .precise) == expected)
    }

    @Test(arguments: [
        (412.0, "$412"),
        (186.0, "$186"),
        (104.70, "$105"),
        (66.10, "$66.10"),
        (1_234.4, "$1,234"),
        (12_400, "$12.4K"),
        (250_000, "$250K"),
        (1_500_000, "$1.5M"),
    ])
    func compactDollars(usd: Double, expected: String) {
        #expect(NumberFormat.dollars(usd) == expected)
    }

    @Test func dollarsFromMicros() {
        #expect(NumberFormat.dollars(micros: 104_700_000, style: .precise) == "$104.70")
        #expect(NumberFormat.dollars(micros: 412_000_000) == "$412")
    }

    @Test(arguments: [
        (0.96, "96%"),
        (0.03, "3.0%"),
        (0.032, "3.2%"),
        (0.006, "0.6%"),
        (0.005, "0.5%"),
        (0.0004, "<0.1%"),
        (0, "0%"),
        (0.63, "63%"),
        (0.0999, "10%"),
        (1, "100%"),
    ])
    func percents(fraction: Double, expected: String) {
        #expect(NumberFormat.percent(fraction) == expected)
    }

    @Test func multiples() {
        #expect(NumberFormat.multiple(8.9266, suffix: "plan") == "8.9× plan")
        #expect(NumberFormat.multiple(4.0) == "4.0×")
        #expect(NumberFormat.multiple(6.9) == "6.9×")
        #expect(NumberFormat.multiple(12.4) == "12×")
        #expect(NumberFormat.multiple(.infinity) == "∞×")
    }
}
