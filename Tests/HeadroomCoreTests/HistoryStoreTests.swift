import Foundation
import Testing
@testable import HeadroomCore
import HeadroomKit

@Suite struct HistoryStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(used: Double, resetsAt: Date, session: Double = 0.2, sessionReset: Date? = nil, at: Date, plan: String = "max") -> LimitReading {
        LimitReading(provider: .claude, fetchedAt: at, source: .api,
                     plan: PlanCatalog.claude(subscriptionType: plan, rateLimitTier: nil),
                     windows: [LimitWindow(id: "session", kind: .session, used: session, resetsAt: sessionReset ?? at.addingTimeInterval(3600)),
                               LimitWindow(id: "weekly", kind: .weekly, used: used, resetsAt: resetsAt)],
                     accountKey: "acct")
    }

    @Test func appendsSamplesOnlyWhenUsageMovesOrTimePasses() {
        var h = HistoryStore()
        let reset = t0.addingTimeInterval(5 * 86400)
        h.record(reading(used: 0.10, resetsAt: reset, at: t0), now: t0)
        h.record(reading(used: 0.10, resetsAt: reset, at: t0.addingTimeInterval(60)), now: t0.addingTimeInterval(60))
        h.record(reading(used: 0.12, resetsAt: reset, at: t0.addingTimeInterval(120)), now: t0.addingTimeInterval(120))
        h.record(reading(used: 0.12, resetsAt: reset, at: t0.addingTimeInterval(3600)), now: t0.addingTimeInterval(3600))
        #expect(h.samples(.claude, account: "acct", window: "weekly").map(\.used) == [0.10, 0.12, 0.12])
    }

    @Test func closesAWeekAtRenewalWithRanOutHoursAndSessionHits() {
        var h = HistoryStore()
        let reset = t0.addingTimeInterval(2 * 86400)
        h.record(reading(used: 0.9, resetsAt: reset, session: 1, sessionReset: t0.addingTimeInterval(1000), at: t0), now: t0)
        h.record(reading(used: 0.95, resetsAt: reset, session: 1, sessionReset: t0.addingTimeInterval(1000), at: t0.addingTimeInterval(600)), now: t0.addingTimeInterval(600))
        let out = reset.addingTimeInterval(-31 * 3600)
        h.record(reading(used: 1.0, resetsAt: reset, at: out), now: out)
        let after = reset.addingTimeInterval(600)
        h.record(reading(used: 0.01, resetsAt: reset.addingTimeInterval(7 * 86400), at: after), now: after)
        let acct = h.account(.claude, "acct")!
        #expect(acct.weeks.count == 1)
        #expect(acct.weeks[0].hoursEarly == 31)
        #expect(acct.weeks[0].sessionHits == 1)
        #expect(acct.weeks[0].earlyReset == false)
        #expect(acct.earlyResetAt == nil)
        #expect(h.samples(.claude, account: "acct", window: "weekly").count == 1)
    }

    @Test func detectsAnEarlyReset() {
        var h = HistoryStore()
        let reset = t0.addingTimeInterval(3 * 86400)
        h.record(reading(used: 0.7, resetsAt: reset, at: t0), now: t0)
        let later = t0.addingTimeInterval(3600)
        h.record(reading(used: 0.0, resetsAt: later.addingTimeInterval(7 * 86400), at: later), now: later)
        let acct = h.account(.claude, "acct")!
        #expect(acct.weeks.last?.earlyReset == true)
        #expect(acct.earlyResetAt == later)
    }

    @Test func accountsAreKeptApart() {
        var h = HistoryStore()
        var r = reading(used: 0.3, resetsAt: t0.addingTimeInterval(86400), at: t0)
        h.record(r, now: t0)
        r.accountKey = "other"
        h.record(r, now: t0)
        #expect(h.accounts.count == 2)
    }

    @Test func thinsLongHistories() {
        var w = WindowHistory(id: "weekly", resetsAt: t0.addingTimeInterval(86400 * 7), duration: 7 * 86400)
        for i in 0..<2000 { w.append(UsageSample(time: t0.addingTimeInterval(Double(i) * 60), used: Double(i) / 4000)) }
        #expect(w.samples.count <= HistoryStore.maxSamples)
        #expect(w.samples.last?.used == 1999.0 / 4000)
    }
}

@Suite struct SessionHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func reading(session: Double, resetsAt: Date?, at: Date) -> LimitReading {
        LimitReading(provider: .claude, fetchedAt: at, source: .api, plan: nil,
                     windows: [LimitWindow(id: "session", kind: .session, used: session, resetsAt: resetsAt),
                               LimitWindow(id: "weekly", kind: .weekly, used: 0.3, resetsAt: t0.addingTimeInterval(5 * 86400))],
                     accountKey: "acct")
    }

    @Test func followsASessionAndRecordsItOnceItResets() {
        var h = HistoryStore()
        let reset = t0.addingTimeInterval(4 * 3600)
        h.record(reading(session: 0.2, resetsAt: reset, at: t0), now: t0)
        h.record(reading(session: 0.7, resetsAt: reset, at: t0.addingTimeInterval(3600)), now: t0.addingTimeInterval(3600))
        h.record(reading(session: 1.0, resetsAt: reset, at: t0.addingTimeInterval(7200)), now: t0.addingTimeInterval(7200))
        #expect(h.account(.claude, "acct")?.session?.samples.count == 3)
        #expect(h.account(.claude, "acct")?.sessions.isEmpty == true)
        // After the reset, nothing used yet (Claude reports no reset time).
        let after = reset.addingTimeInterval(600)
        h.record(reading(session: 0, resetsAt: nil, at: after), now: after)
        let acct = h.account(.claude, "acct")!
        #expect(acct.session == nil)
        #expect(acct.sessions.count == 1)
        #expect(acct.sessions[0].peakUsed == 1)
        #expect(acct.sessions[0].hitLimitAt == t0.addingTimeInterval(7200))
        #expect(abs(acct.sessions[0].cutShort! - 2 * 3600) < 1)
    }

    @Test func aNewResetTimeStartsANewSession() {
        var h = HistoryStore()
        h.record(reading(session: 0.4, resetsAt: t0.addingTimeInterval(600), at: t0), now: t0)
        let later = t0.addingTimeInterval(1200)
        h.record(reading(session: 0.1, resetsAt: later.addingTimeInterval(5 * 3600), at: later), now: later)
        let acct = h.account(.claude, "acct")!
        #expect(acct.sessions.map(\.peakUsed) == [0.4])
        #expect(acct.sessions[0].hitLimit == false)
        #expect(acct.recentSessions(now: later).map(\.inProgress) == [false, true])
    }

    @Test func decodesStateSavedBeforeSessionsWereTracked() throws {
        let old = #"{"accounts":{"claude:acct":{"windows":{},"weeks":[],"sessionHitsThisWindow":2}}}"#
        let h = try JSONDecoder().decode(HistoryStore.self, from: Data(old.utf8))
        #expect(h.accounts["claude:acct"]?.sessions == [])
        #expect(h.accounts["claude:acct"]?.sessionHitsThisWindow == 2)
    }
}
