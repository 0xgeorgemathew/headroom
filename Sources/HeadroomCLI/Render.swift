import Foundation
import HeadroomKit

/// `headroom` summary: one line per provider, then ↳ lines for the verdict, the 5-hour session
/// warning (≥ 75%), blocks, faults and reset credits.
enum Summary {
    static func render(_ s: Snapshot, style: Style, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var lines: [String] = []
        let alive = SnapshotFile.writerIsAlive(s)
        let shown = s.providers.sorted { $0.id < $1.id }
        let nameWidth = (shown.map { $0.id.displayName.count }.max() ?? 6) + 2
        for p in shown {
            let name = p.id.displayName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            guard let w = p.weekly else {
                var line = style.bold(name) + style.dim("no reading yet")
                if let f = p.fault { line += "\n  ↳ " + style.paint("⚠ " + f.message, 0xFF6982) }
                lines.append(line)
                continue
            }
            let state = w.pacingState
            let cells = (0..<5).map { $0 < w.cells ? state.emojiCell : PacingState.emptyEmojiCell }.joined()
            let pct = "\(Int((w.left * 100).rounded()))%".leftPad(4)
            var head = "\(style.bold(name))\(cells)  \(pct) · renews in \(TimeFormat.compact(w.resetsAt.timeIntervalSince(now)))"
            if w.hourglass { head += " ⏳" }
            if let label = w.label { head += style.dim(" (\(label) cap)") }
            lines.append(head)

            if let b = p.blocked {
                lines.append("  ↳ " + style.paint("⏸ " + blockedText(b, now: now, calendar: calendar, locale: locale), 0xFF6982))
            } else {
                lines.append("  ↳ " + style.paint(state.word, Style.hex(for: state)) + " · " + verdictDetail(w, now: now, calendar: calendar, locale: locale))
            }
            if let sess = p.session, sess.sessionLevel < .blocked, let line = sessionLine(sess, style: style, now: now, calendar: calendar, locale: locale) {
                lines.append("  ↳ " + line)
            }
            for cap in p.caps where cap.used >= 1 {
                var text = "\(cap.label) cap reached"
                if let r = cap.resetsAt { text += " · resets \(TimeFormat.shortDayTime(r, now: now, calendar: calendar, locale: locale))" }
                lines.append("  ↳ " + style.paint(text, 0xFF6982))
            }
            if let c = p.credits, c.available > 0 {
                if c.expiringSoon > 0, let exp = c.nextExpiry {
                    let noun = c.expiringSoon == 1 ? "reset credit lapses" : "reset credits lapse"
                    lines.append("  ↳ " + style.paint("⏳ \(c.expiringSoon) \(noun) in \(TimeFormat.compact(exp.timeIntervalSince(now)))", Style.credit))
                } else {
                    lines.append("  ↳ " + style.dim("\(c.available) reset credit\(c.available == 1 ? "" : "s") available"))
                }
            }
            if let f = p.fault {
                let age = p.readingAt.map { " · reading \(TimeFormat.compact(now.timeIntervalSince($0))) old" } ?? ""
                lines.append("  ↳ " + style.paint("⚠ " + f.message + age, 0xFF6982))
            }
        }
        if !alive {
            lines.append(style.dim("(Headroom isn't running · snapshot \(TimeFormat.compact(now.timeIntervalSince(s.generatedAt))) old)"))
        }
        return lines.joined(separator: "\n")
    }

    /// The 5-hour session: a warning from the user's threshold, a heads-up when the recent pace
    /// runs it out before the reset, and a quiet line otherwise. Nothing while no session runs.
    static func sessionLine(_ sess: SessionSnapshot, style: Style, now: Date, calendar: Calendar, locale: Locale) -> String? {
        if sess.outlook == "idle" { return nil }
        let left = "\(Int((sess.left * 100).rounded()))% left"
        let resets = sess.resetsAt.map { " · resets \(TimeFormat.shortClock($0, calendar: calendar, locale: locale))" } ?? ""
        var runsOut = ""
        if let out = sess.runsOutAt {
            runsOut = " · runs out ~\(TimeFormat.shortClock(out, calendar: calendar, locale: locale))"
            if let r = sess.resetsAt { runsOut += ", \(TimeFormat.compact(r.timeIntervalSince(out))) early" }
        }
        if sess.sessionLevel >= .amber {
            return style.paint("⚠ 5-hour session \(left)\(resets)\(runsOut)", Style.hex(for: sess.sessionLevel))
        }
        if !runsOut.isEmpty {
            return style.paint("5-hour session \(left)\(runsOut)", 0xFFC248)
        }
        guard sess.outlook != nil else { return nil } // older apps: only the warning, as before
        var text = "5-hour session \(left)\(resets)"
        if let l = sess.leftAtReset, l >= 0.01 { text += " · ~\(Int((l * 100).rounded()))% spare at this pace" }
        return style.dim(text)
    }

    static func verdictDetail(_ w: WeeklySnapshot, now: Date, calendar: Calendar, locale: Locale) -> String {
        if w.left <= 0 {
            return "limit reached · back \(TimeFormat.shortDayTime(w.resetsAt, now: now, calendar: calendar, locale: locale))"
        }
        if let runOut = w.runsOutAt, runOut < w.resetsAt {
            let early = TimeFormat.compact(w.resetsAt.timeIntervalSince(runOut))
            return "runs out \(TimeFormat.shortDayTime(runOut, now: now, calendar: calendar, locale: locale)), \(early) early"
        }
        switch w.pacingState {
        case .plenty:
            if let u = w.unusedAtReset, u >= 0.005 { return "\(Int((u * 100).rounded()))% renews unused at this pace" }
            return "spend it before it renews"
        case .onPace:
            return "lasts to renewal at this pace"
        case .tight, .veryTight:
            return w.verdict.primary.prefix(1).lowercased() + w.verdict.primary.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }

    static func blockedText(_ b: BlockedSnapshot, now: Date, calendar: Calendar, locale: Locale) -> String {
        let what: String = switch b.by {
        case "session": "5-hour limit reached"
        case "weekly": "weekly limit reached"
        case "model_cap": "\(b.detail ?? "model") cap reached"
        default: b.detail ?? "service outage"
        }
        guard let until = b.until else { return what }
        return "\(what) · back \(TimeFormat.shortDayTime(until, now: now, calendar: calendar, locale: locale)) (\(TimeFormat.compact(until.timeIntervalSince(now))))"
    }
}

/// `headroom statusline`: one short line for prompts, tmux, SketchyBar or Claude Code.
enum StatusLine {
    enum Format: String { case claude, tmux, sketchybar, plain }

    static func render(_ s: Snapshot, format: Format, only: Provider?, colors: Bool, now: Date) -> String {
        let useColor = colors && (format == .claude || format == .tmux)
        func paint(_ text: String, _ hex: UInt32?) -> String {
            guard useColor, let hex else { return text }
            switch format {
            case .tmux: return "#[fg=#\(String(hex, radix: 16, uppercase: true))]\(text)#[default]"
            default: return Style(colors: true).paint(text, hex)
            }
        }
        var parts: [String] = []
        for p in s.providers.sorted(by: { $0.id < $1.id }) where only == nil || only == p.id {
            guard let w = p.weekly else {
                if p.fault != nil { parts.append("\(p.id.displayName) ⚠") }
                continue
            }
            let state = w.pacingState
            let cells = (0..<5).map { $0 < w.cells ? state.emojiCell : PacingState.emptyEmojiCell }.joined()
            var part = "\(p.id.displayName) \(cells) \(Int((w.left * 100).rounded()))%"
            if let b = p.blocked {
                let left = b.until.map { TimeFormat.compact($0.timeIntervalSince(now)) } ?? ""
                part += " " + paint("⏸\(left)", 0xFF6982)
            } else if let sess = p.session, sess.sessionLevel >= .amber, let r = sess.resetsAt {
                part += " " + paint("⏱\(TimeFormat.compact(r.timeIntervalSince(now)))", Style.hex(for: sess.sessionLevel))
            } else if w.hourglass {
                part += " ⏳"
            }
            if p.fault != nil { part += " ⚠" }
            parts.append(part)
        }
        if !SnapshotFile.writerIsAlive(s) && now.timeIntervalSince(s.generatedAt) > 3600 { parts.append("(stale)") }
        return parts.isEmpty ? "Headroom: no data" : parts.joined(separator: "  ")
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
