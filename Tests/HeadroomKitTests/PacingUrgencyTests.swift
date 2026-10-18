import Foundation
import Testing
@testable import HeadroomKit

@Suite("Session and urgency")
struct PacingUrgencyTests {
    let now = PT.date(2026, 10, 20, 10, 2)

    @Test func sessionLevels() {
        #expect(SessionLevel(used: 0.74) == .normal)
        #expect(SessionLevel(used: 0.75) == .amber)
        #expect(SessionLevel(used: 0.89) == .amber)
        #expect(SessionLevel(used: 0.90) == .rose)
        #expect(SessionLevel(used: 0.99) == .rose)
        #expect(SessionLevel(used: 1.0) == .blocked)
    }

    @Test func sessionStatus() {
        let w = LimitWindow(id: "session", kind: .session, used: 0.84, resetsAt: now.addingTimeInterval(48 * 60))
        let s = try! #require(SessionStatus(window: w, now: now))
        #expect(s.level == .amber)
        #expect(s.showsBanner)
        #expect(abs(s.remaining - 0.16) < 1e-9)
        #expect(abs((s.countdown ?? 0) - 48 * 60) < 0.001)
        #expect(s.title == "5-hour session almost used")
        #expect(SessionStatus(window: PT.weekly(used: 0.1, resetsAt: now), now: now) == nil)
        // A session whose reset has passed reads as fresh.
        let stale = LimitWindow(id: "session", kind: .session, used: 1, resetsAt: now.addingTimeInterval(-60))
        #expect(SessionStatus(window: stale, now: now)?.level == .normal)
    }

    func session(_ used: Double) -> SessionStatus {
        SessionStatus(level: SessionLevel(used: used), used: used, resetsAt: now.addingTimeInterval(3600), countdown: 3600)
    }

    @Test func headlineOrder() {
        let blocked = UrgencyInput(provider: .claude, pacing: .plenty, session: session(1.0), weeklyExhausted: true)
        #expect(UrgencyResolver.headline(blocked) == .blocked(reason: .session, until: now.addingTimeInterval(3600)))

        let weekly = UrgencyInput(provider: .claude, pacing: .veryTight, session: session(0.95), weeklyExhausted: true, weeklyResetsAt: now)
        #expect(UrgencyResolver.headline(weekly) == .blocked(reason: .weekly, until: now))

        let cap = UrgencyInput(provider: .claude, pacing: .onPace, session: session(0.2), blockedCaps: [.init(label: "Fable", resetsAt: nil)])
        #expect(UrgencyResolver.headline(cap) == .blocked(reason: .modelCap("Fable"), until: nil))

        let outage = UrgencyInput(provider: .codex, pacing: .onPace, majorOutage: "Codex major outage")
        #expect(UrgencyResolver.headline(outage) == .blocked(reason: .outage("Codex major outage"), until: nil))

        let warn = UrgencyInput(provider: .codex, pacing: .plenty, session: session(0.92))
        #expect(UrgencyResolver.headline(warn) == .session(level: .rose, resetsAt: now.addingTimeInterval(3600)))

        let plain = UrgencyInput(provider: .codex, pacing: .tight, session: session(0.5))
        #expect(UrgencyResolver.headline(plain) == .weekly(.tight))
    }

    @Test func mostUrgent() {
        let a = UrgencyInput(provider: .claude, pacing: .veryTight, session: session(0.3))
        let b = UrgencyInput(provider: .codex, pacing: .plenty, session: session(0.8))
        #expect(UrgencyResolver.mostUrgent([a, b]) == .codex) // session warning beats pacing
        let c = UrgencyInput(provider: .claude, pacing: .plenty, session: session(1.0))
        #expect(UrgencyResolver.mostUrgent([c, b]) == .claude) // blocked beats warning
        let d = UrgencyInput(provider: .claude, pacing: .tight)
        let e = UrgencyInput(provider: .codex, pacing: .veryTight)
        #expect(UrgencyResolver.mostUrgent([d, e]) == .codex) // tightest pacing
        let f = UrgencyInput(provider: .claude, pacing: .onPace)
        let g = UrgencyInput(provider: .codex, pacing: .onPace)
        #expect(UrgencyResolver.mostUrgent([f, g]) == .claude) // tie → Claude
        let h = UrgencyInput(provider: .codex, pacing: .plenty, hourglass: true)
        #expect(UrgencyResolver.mostUrgent([f, h]) == .codex) // about to waste allowance
        let i = UrgencyInput(provider: .claude, pacing: .plenty, session: session(0.9))
        let j = UrgencyInput(provider: .codex, pacing: .plenty, session: session(0.8))
        #expect(UrgencyResolver.mostUrgent([j, i]) == .claude) // closest to its session limit
        #expect(UrgencyResolver.mostUrgent([]) == nil)
    }
}
