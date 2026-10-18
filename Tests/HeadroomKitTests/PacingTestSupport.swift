import Foundation
@testable import HeadroomKit

enum PT {
    static let tz = TimeZone(identifier: "America/Los_Angeles")!
    static let locale = Locale(identifier: "en_US")
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static let week: TimeInterval = 7 * 86400

    /// A weekly window used `used`, renewing at `resetsAt`.
    static func weekly(used: Double, resetsAt: Date, duration: TimeInterval = week) -> LimitWindow {
        LimitWindow(id: "weekly", kind: .weekly, used: used, resetsAt: resetsAt, duration: duration)
    }

    /// Samples rising linearly from `fromUsed` at `from` to `toUsed` at `to`, hourly.
    static func linear(from: Date, fromUsed: Double, to: Date, toUsed: Double) -> [UsageSample] {
        var out: [UsageSample] = []
        let span = to.timeIntervalSince(from)
        var t: TimeInterval = 0
        while t <= span {
            out.append(UsageSample(time: from.addingTimeInterval(t), used: fromUsed + (toUsed - fromUsed) * t / span))
            t += 3600
        }
        return out
    }

    /// Deterministic generator for property tests.
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
