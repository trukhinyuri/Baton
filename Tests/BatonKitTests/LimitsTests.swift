import Foundation
import Testing

@testable import BatonKit

private let utc = TimeZone(identifier: "UTC")!
/// A 24-hour locale, so times read the same on every Mac.
private let gb = Locale(identifier: "en_GB")
/// Mon 2026-09-28 20:00 UTC.
private let base = Date(timeIntervalSince1970: 1_790_625_600)
private let org = "0d9e8c7b-0000-4000-8000-000000000001"
private let otherOrg = "0d9e8c7b-0000-4000-8000-000000000002"
private let session = "11111111-2222-3333-4444-555555555555"

private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

private func sample(_ minutes: Double, fh: Int?, sd: Int?, xu: Int? = nil, org: String? = org) -> UsageSample {
    UsageSample(at: at(minutes), org: org, fiveHour: fh, week: sd, extraUsage: xu)
}

private func hit(_ kind: LimitKind, _ minutes: Double, resets: Double, session: String = session) -> LimitHit {
    LimitHit(kind: kind, at: at(minutes), resetsAt: at(resets), session: session)
}

/// A transcript line as Claude Code writes it when Claude refuses a request at a limit.
private func limitLine(_ kind: LimitKind, at date: Date, resets: Date, session: String = session, entrypoint: String = "claude-desktop") -> String {
    let stamp = ISO8601DateFormatter.string(from: date, timeZone: utc, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    return
        #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"sessionId":"\#(session)","entrypoint":"\#(entrypoint)","version":"2.1.284","timestamp":"\#(stamp)","quotaLimits":{"status":"rejected","resetsAt":\#(Int(resets.timeIntervalSince1970)),"rateLimitType":"\#(kind.rawValue)","overageStatus":"rejected","overageDisabledReason":"org_level_disabled","isUsingOverage":false,"unifiedRateLimitFallbackAvailable":false},"message":{"role":"assistant","content":[]}}"#
}

private func status(_ id: String, limits: Limits, usage: Usage?, signedIn: Bool = true) -> ProfileStatus {
    ProfileStatus(
        profile: id == "main" ? nil : Profile(id: id, label: id.uppercased(), email: nil, color: "#123456"),
        accountID: signedIn ? "acct-\(id)" : nil, email: signedIn ? "\(id)@x.com" : nil, usage: usage, isRunning: true, limits: limits)
}

@Suite("Usage samples")
struct UsageHistoryTests {
    @Test func readsBothFormatsNumbersAndExtraUsage() {
        let v2 =
            #"{"version":2,"samples":[{"t":1790625600000,"org":"\#(org.uppercased())","u":{"fh":12.9,"sd":100,"xu":40}},{"t":1790625000000,"org":null,"u":{"fh":1}}]}"#
        let samples = UsageHistory.samples(from: Data(v2.utf8))
        #expect(samples.map(\.at) == [base.addingTimeInterval(-600), base], "oldest first")
        #expect(samples.last == UsageSample(at: base, org: org, fiveHour: 12, week: 100, extraUsage: 40), "rounded down, org lowercased")
        let v1 = #"{"version":1,"samples":[{"t":1790625600000,"fh":7,"sd":30}]}"#
        #expect(UsageHistory.samples(from: Data(v1.utf8)) == [UsageSample(at: base, fiveHour: 7, week: 30)])
        #expect(UsageHistory.samples(from: Data("[1,2]".utf8)).isEmpty && UsageHistory.samples(from: Data("oops".utf8)).isEmpty)
    }

    @Test func usesTheWindowsCurrentOrganizationAndTheNewestOverallOnlyWhenUnknown() throws {
        let samples = [sample(0, fh: 10, sd: 20), sample(5, fh: 90, sd: 95, org: otherOrg)]
        #expect(UsageHistory.current(samples, organizations: [org]).map(\.fiveHour) == [10], "another account's newer sample doesn't count")
        #expect(UsageHistory.current(samples, organizations: []).map(\.fiveHour) == [90], "no organization of its own known: the one sampled last")
        #expect(
            UsageHistory.current(samples, organizations: [], otherAccounts: [otherOrg]).map(\.fiveHour) == [10],
            "but not one another account's folders name")
        #expect(UsageHistory.current([sample(0, fh: 1, sd: 2, org: nil)], organizations: [org]).count == 1, "the file doesn't say: every sample")
        #expect(UsageHistory.current(samples, organizations: ["ffffffff-0000-4000-8000-000000000000"]).isEmpty, "none of this account's yet")

        let box = try Sandbox()
        let file = box.work.appending(path: UsageHistory.fileName)
        try box.write(
            #"{"version":2,"samples":[{"t":1790625600000,"org":"\#(org)","u":{"fh":10,"sd":20}},{"t":1790625900000,"org":"\#(otherOrg)","u":{"fh":90,"sd":95}}]}"#,
            to: file)
        #expect(DesktopData.usage(in: box.work)?.week == 95, "not signed in: the newest sample")
        // Claude rewrites config.json when it refreshes the sign-in or quits: newer than every sample, it says nothing.
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: box.work.appending(path: "config.json"), modified: Date())
        #expect(DesktopData.usage(in: box.work)?.week == 95, "no organization folder yet: the organization sampled last")
        try box.pair(box.work, account: Sandbox.accountA, org: otherOrg)
        #expect(DesktopData.usage(in: box.work)?.week == 20, "not the one a previous account's folders name")
        try box.pair(box.work, account: Sandbox.accountB, org: org)
        #expect(DesktopData.usage(in: box.work) == Usage(fiveHour: 10, week: 20, sampledAt: base), "the signed-in account's organization")
    }
}

@Suite("Limit resets")
struct LimitStateTests {
    @Test func aLimitIsOverNinetySecondsAfterItsExactReset() {
        let limits = Limits(samples: [sample(0, fh: 100, sd: 40)], hits: [hit(.fiveHour, 1, resets: 130)])
        #expect(limits.fiveHour.reset == LimitReset(at: at(130), source: .exact))
        #expect(limits.isAtLimit(now: at(130).addingTimeInterval(89)))
        #expect(!limits.isAtLimit(now: at(130).addingTimeInterval(90)))
        #expect(limits.fiveHour.phase(now: at(132)) == .reset)
        #expect(limits.nextChange(after: at(60)) == at(131.5))
        #expect(limits.nextChange(after: at(132)) == nil)
    }

    @Test func aLimitMessageAfterTheLastSampleBelowCountsAndAnOlderOneDoesNot() {
        let reached = Limits(samples: [sample(0, fh: 80, sd: 10)], hits: [hit(.fiveHour, 10, resets: 120)])
        #expect(reached.fiveHour.percent == 100 && reached.isAtLimit(now: at(60)))
        let old = Limits(samples: [sample(0, fh: 80, sd: 10)], hits: [hit(.fiveHour, -10, resets: 120)])
        #expect(!old.isAtLimit(now: at(60)), "the sample after it shows room")
        let again = Limits(samples: [sample(0, fh: 100, sd: 10), sample(200, fh: 100, sd: 12)], hits: [hit(.fiveHour, 1, resets: 120)])
        #expect(again.fiveHour.reset == nil && again.isAtLimit(now: at(210)), "reached again after that reset, at a time Claude hasn't said")
    }

    @Test func autoContinueEntriesGiveTheFiveHourReset() {
        let limits = Limits(samples: [sample(0, fh: 97, sd: 10)], autoResume: [at(240)])
        #expect(limits.fiveHour.reset?.source == .exact && limits.isAtLimit(now: at(100)))
        #expect(limits.fiveHour.percent == 100, "reached after the 97% sample")
        #expect(!limits.isAtLimit(now: at(241.5)))
        #expect(!Limits(samples: [sample(300, fh: 3, sd: 10)], autoResume: [at(240)]).isAtLimit(now: at(301)), "a sample after the reset rules")
    }

    @Test func anEstimateIsShownAsAboutAndNeverFreesAWindow() {
        // Reset times are weekly: a week-old one, moved on by a week, is Wed 05:00 UTC after Mon 20:00.
        let anchor = at(-7 * 24 * 60 + 33 * 60)
        let samples = [sample(-10 * 24 * 60, fh: 5, sd: 50), sample(0, fh: 20, sd: 100)]
        let limits = Limits(samples: samples, hits: [hit(.week, -7 * 24 * 60 - 60, resets: -7 * 24 * 60 + 33 * 60)])
        #expect(limits.week.reset == LimitReset(at: anchor.addingTimeInterval(7 * 86_400), source: .estimate))
        #expect(LimitText.describe(limits.week, now: at(1), timeZone: utc, locale: gb) == "week 100% · resets Wed at about 05:00")
        let after = at(34 * 60)
        #expect(limits.isAtLimit(now: after), "an estimate never frees")
        #expect(LimitText.describe(limits.week, now: after, timeZone: utc, locale: gb) == "week 100% · may have reset at about 05:00")
        #expect(limits.nextChange(after: at(1)) == nil, "only exact resets are scheduled")
        #expect(!limits.isAtLimit(now: at(7 * 24 * 60 + 1)) && limits.week.phase(now: at(7 * 24 * 60 + 1)) == .mayHaveReset)
        // A reset seen at another time of the week: the schedule moved, so no estimate.
        let moved = Limits(
            samples: [
                sample(-10 * 24 * 60, fh: 5, sd: 50), sample(-3 * 24 * 60, fh: 5, sd: 90), sample(-2 * 24 * 60, fh: 5, sd: 10), sample(0, fh: 5, sd: 100),
            ],
            hits: [hit(.week, -7 * 24 * 60 - 60, resets: -7 * 24 * 60 + 33 * 60)])
        #expect(moved.week.reset == nil && moved.isAtLimit(now: at(1)))
    }

    @Test func aLowerLaterSampleFreesAWindowAndSaysItWasInferred() {
        let limits = Limits(samples: [sample(0, fh: 100, sd: 40), sample(300, fh: 4, sd: 41)])
        #expect(!limits.isAtLimit(now: at(301)))
        #expect(limits.fiveHour.reset == LimitReset(at: at(300), source: .inferred))
    }

    @Test func extraUsageKeepsAHundredPercentFromBlockingUntilClaudeRefuses() {
        let extra = Limits(samples: [sample(0, fh: 20, sd: 100, xu: 40)])
        #expect(extra.week.extraUsage && !extra.isAtLimit(now: at(1)))
        #expect(LimitText.describe(extra.week, now: at(1)) == "week 100%, extra usage available")
        let spent = Limits(samples: [sample(0, fh: 20, sd: 100, xu: 100)])
        #expect(spent.isAtLimit(now: at(1)))
        let refused = Limits(samples: [sample(0, fh: 20, sd: 100, xu: 40)], hits: [hit(.week, 1, resets: 3000)])
        #expect(!refused.week.extraUsage && refused.isAtLimit(now: at(2)), "Claude's own refusal overrides")
    }

    @Test func withoutAResetTimeTheOldFallbackHoldsAndThenMayHaveReset() {
        let limits = Limits(usage: Usage(fiveHour: 100, week: 100, sampledAt: base))
        #expect(limits.isAtLimit(now: at(4 * 60)))
        #expect(limits.fiveHour.phase(now: at(5 * 60)) == .mayHaveReset && limits.isAtLimit(now: at(5 * 60)), "the week still holds")
        let later = at(7 * 24 * 60)
        #expect(!limits.isAtLimit(now: later))
        #expect(
            LimitText.summary(limits, usage: Usage(fiveHour: 100, week: 100, sampledAt: base), now: later)
                == "5h reset · week reset · as of 7d ago", "older than its own window: certainly reset")
        let quiet = Usage(fiveHour: 10, week: 20, sampledAt: base)
        #expect(LimitText.summary(Limits(usage: quiet), usage: quiet, now: at(4 * 60)) == "5h 10% · week 20% · as of 4h ago (stale: may have changed since)")
        #expect(LimitText.summary(Limits(usage: nil), usage: nil) == "usage unknown")
    }

    @Test func textsNameTheResetTime() {
        let limits = Limits(samples: [sample(0, fh: 100, sd: 40)], hits: [hit(.fiveHour, 1, resets: 370)])
        #expect(
            LimitText.summary(limits, usage: Usage(fiveHour: 100, week: 40, sampledAt: base), now: at(2), timeZone: utc, locale: gb)
                == "5h 100% · resets tomorrow at 02:10 · week 40% · as of 2m ago")
        #expect(LimitText.bindingReset(limits, now: at(2), timeZone: utc, locale: gb) == "resets tomorrow at 02:10")
        #expect(LimitText.bindingReset(limits, now: at(300), timeZone: utc, locale: gb) == "resets at 02:10", "the same day: no day")
        #expect(LimitText.note(limits.fiveHour, now: at(300), timeZone: utc, locale: gb) == "5h resets at 02:10")
        #expect(LimitText.atLimit(limits, now: at(300), timeZone: utc, locale: gb) == "at its limit, resets at 02:10")
        #expect(LimitText.describe(limits.fiveHour, now: at(380), timeZone: utc, locale: gb) == "5h reset at 02:10")
        #expect(LimitText.time(at(3 * 24 * 60), now: base, timeZone: utc, locale: gb) == "Thu at 20:00")
        #expect(LimitText.time(at(-1), now: base, timeZone: utc, locale: gb) == "at 19:59")
        #expect(LimitText.time(at(-24 * 60), now: base, timeZone: utc, locale: gb) == "yesterday at 20:00")
        #expect(LimitText.time(at(6 * 24 * 60), now: base, timeZone: utc, locale: gb) == "Sun 4 Oct at 20:00", "a weekday alone would read as this week's")
        #expect(LimitText.time(at(370), now: base, about: true, timeZone: utc, locale: gb) == "tomorrow at about 02:10")
        #expect(LimitText.stamp(at(-1), now: base, timeZone: utc, locale: gb) == "19:59")
        let twelve = LimitText.time(at(370), now: base, timeZone: utc, locale: Locale(identifier: "en_US"))
        #expect(twelve.hasPrefix("tomorrow at 2:10") && twelve.hasSuffix("AM"), "the user's clock style")
        #expect(LimitText.bindingReset(limits, now: at(2), timeZone: utc, locale: gb).map { "It \($0)." } == "It resets tomorrow at 02:10.", "the banner")
    }

    @Test func aLimitHeldBackByASampleAloneSaysAsOfWhenAndAClosedWindowSaysToOpenIt() {
        let limits = Limits(samples: [sample(0, fh: 20, sd: 100)])
        #expect(limits.week.sampleOnly && LimitText.bindingReset(limits, now: at(5)) == nil)
        #expect(LimitText.atLimit(limits, now: at(5), timeZone: utc, locale: gb) == "at its limit as of 20:00")
        var closed = status("work", limits: limits, usage: Usage(fiveHour: 20, week: 100, sampledAt: base))
        closed.isRunning = false
        #expect(LimitText.checkHint(closed, now: at(5)) != nil)
        closed.isRunning = true
        #expect(LimitText.checkHint(closed, now: at(5)) == nil, "an open window samples by itself")
        let told = Limits(samples: [sample(0, fh: 20, sd: 100)], hits: [hit(.week, 1, resets: 3000)])
        #expect(!told.week.sampleOnly && LimitText.asOf(told, now: at(5)) == nil)
    }

    /// Hit the five-hour limit (its auto-continue entry resets at +370 min), then Claude reset it early: the next
    /// sample reads 0%.
    @Test func anEarlyResetOverridesAnAutoContinueEntry() {
        let samples = [sample(0, fh: 50, sd: 10), sample(80, fh: 100, sd: 12), sample(100, fh: 0, sd: 12)]
        let limits = Limits(samples: samples, autoResume: [at(370)])
        #expect(!limits.isAtLimit(now: at(101)) && limits.fiveHour.phase(now: at(101)) == .below)
        #expect(LimitText.describe(limits.fiveHour, now: at(101)) == "5h 0%")
        let rising = Limits(samples: [sample(0, fh: 50, sd: 10), sample(100, fh: 97, sd: 12)], autoResume: [at(370)])
        #expect(rising.isAtLimit(now: at(101)), "usage only rose: the entry stands")
        let atTheStart = Limits(samples: [sample(60, fh: 100, sd: 10), sample(75, fh: 0, sd: 12)], autoResume: [at(370)])
        #expect(atTheStart.isAtLimit(now: at(101)), "a drop right at the start of the entry's window is its own reset")
        // The entry's window runs from +70; its first sample comes 20 minutes in, lower than the previous window's last.
        let previous = Limits(samples: [sample(0, fh: 95, sd: 10), sample(90, fh: 5, sd: 11), sample(200, fh: 80, sd: 12)], autoResume: [at(370)])
        #expect(previous.isAtLimit(now: at(301)) && previous.fiveHour.reset == LimitReset(at: at(370), source: .exact), "the previous window ending")
    }

    /// A real window's five-hour samples of 28.09 (minutes from 21:10, the start of the window whose auto-continue
    /// entry resets at 02:10): 20:56:50 63%, 21:11:50 91%, 21:26:50 24%, 21:41:50 62%, 21:56:50 95%, 22:04:41 100%.
    @Test func aNewWindowsFirstSampleDoesNotCancelItsEntry() {
        let samples = [
            sample(-13.17, fh: 63, sd: 13), sample(1.83, fh: 91, sd: 17), sample(16.83, fh: 24, sd: 4), sample(31.83, fh: 62, sd: 11),
            sample(46.83, fh: 95, sd: 16), sample(54.68, fh: 100, sd: 17),
        ]
        let limits = Limits(samples: samples, autoResume: [at(300)])
        #expect(limits.fiveHour.reset == LimitReset(at: at(300), source: .exact))
        #expect(LimitText.atLimit(limits, now: at(60), timeZone: utc, locale: gb) == "at its limit, resets tomorrow at 01:00")
        #expect(limits.isAtLimit(now: at(301)) && limits.fiveHour.phase(now: at(302)) == .reset, "freed, and announced, at the reset")
    }

    /// Claude writes `xu` only on its full polls: the verdict doesn't flip with each poll.
    @Test func theExtraUsageVerdictDoesNotDependOnWhetherTheLatestPollWasAFullOne() {
        let withXuLast = Limits(samples: [sample(0, fh: 10, sd: 100), sample(5, fh: 11, sd: 100, xu: 40)])
        let withoutXuLast = Limits(samples: [sample(0, fh: 10, sd: 100, xu: 40), sample(5, fh: 11, sd: 100)])
        #expect(!withXuLast.isAtLimit(now: at(6)) && !withoutXuLast.isAtLimit(now: at(6)))
        let beforeTheLimit = Limits(samples: [sample(0, fh: 10, sd: 90, xu: 40), sample(5, fh: 11, sd: 100)])
        #expect(beforeTheLimit.isAtLimit(now: at(6)), "an xu from before the limit was reached doesn't count")
        let old = Limits(samples: [sample(0, fh: 10, sd: 100, xu: 40), sample(180, fh: 11, sd: 100)])
        #expect(old.isAtLimit(now: at(181)), "more than two hours old")
    }

    /// Claude answered in one of the window's sessions after its last sample at 100%: the limit was reset then.
    @Test func aReplyAfterTheLimitFreesTheWindowAsSeenNotEstimated() {
        let limits = Limits(samples: [sample(0, fh: 20, sd: 100)], answeredAt: at(2), askedAt: at(1.5))
        #expect(!limits.isAtLimit(now: at(3)) && limits.week.phase(now: at(3)) == .below && limits.week.resetByAnswer)
        #expect(limits.week.reset == LimitReset(at: at(2), source: .inferred))
        #expect(LimitText.describe(limits.week, now: at(3)) == "week: Claude answered since" && limits.load(now: at(3)) == 20)
        #expect(
            Limits(samples: [sample(0, fh: 20, sd: 100)], answeredAt: at(-1), askedAt: at(-1.5)).isAtLimit(now: at(3)),
            "a reply before the sample proves nothing")
        #expect(
            Limits(samples: [sample(0, fh: 20, sd: 100)], answeredAt: at(2), askedAt: at(0.5)).isAtLimit(now: at(3)),
            "asked for within a minute of the sample: it may have been admitted before the limit")
        #expect(Limits(samples: [sample(0, fh: 20, sd: 100)], answeredAt: at(2)).isAtLimit(now: at(3)), "when it was asked for isn't known")
        let refused = Limits(samples: [sample(0, fh: 20, sd: 90)], hits: [hit(.week, 5, resets: 5000)], answeredAt: at(3), askedAt: at(2.5))
        #expect(refused.isAtLimit(now: at(6)), "a refusal after the reply still holds")
        let entryOnly = Limits(samples: [sample(0, fh: 90, sd: 10)], autoResume: [at(200)], answeredAt: at(150), askedAt: at(149))
        #expect(entryOnly.isAtLimit(now: at(151)), "with only an entry, the time of the refusal isn't known")
        let olderReach = Limits(
            samples: [sample(-3000, fh: 100, sd: 10), sample(0, fh: 97, sd: 12)], autoResume: [at(250)], answeredAt: at(3), askedAt: at(2.5))
        #expect(olderReach.isAtLimit(now: at(10)), "a 100% sample from an earlier reach proves nothing about this one")

        // Held back by a limit message after a 90% sample, then Claude answered: not 90% any more.
        let told = Limits(samples: [sample(0, fh: 90, sd: 12)], hits: [hit(.fiveHour, 5, resets: 300)], answeredAt: at(200), askedAt: at(199))
        #expect(!told.isAtLimit(now: at(201)) && told.fiveHour.resetByAnswer)
        #expect(LimitText.describe(told.fiveHour, now: at(201)) == "5h: Claude answered since")
        #expect(LimitText.note(told.fiveHour, now: at(201)) == "5h: Claude answered since the limit")
        #expect(told.fiveHour.load(now: at(201)) == 0)
        #expect(LimitSchedule.roomAgainReason(status("work", limits: told, usage: nil)) == "Claude answered in it again.", "extra usage may be paying")
        #expect(LimitSchedule.roomAgainReason(status("work", limits: Limits(usage: nil), usage: nil)) == "Its usage limit has reset.")

        let before = LimitSchedule.blocked([status("work", limits: Limits(samples: [sample(0, fh: 20, sd: 100)]), usage: nil)], now: at(1))
        #expect(LimitSchedule.freed(blockedBefore: before, [status("work", limits: limits, usage: nil)], now: at(3)).map(\.id) == ["work"])
    }

    @Test func readsRepliesButNotErrorsOrClaudeCodesOwnRecords() {
        let stamp = { (date: Date) in ISO8601DateFormatter.string(from: date, timeZone: utc, formatOptions: [.withInternetDateTime, .withFractionalSeconds]) }
        let reply = { (date: Date, extra: String) in
            #"{"type":"assistant","requestId":"req_1","sessionId":"\#(session)","entrypoint":"claude-desktop","version":"2.1.284","timestamp":"\#(stamp(date))","message":{"model":"claude-opus-5-5","role":"assistant"}\#(extra)}"#
        }
        let lines = [
            reply(at(1), ""),
            reply(at(2), "").replacingOccurrences(of: "claude-opus-5-5", with: "<synthetic>"),
            reply(at(3), "").replacingOccurrences(of: #""requestId":"req_1","#, with: ""),
            limitLine(.week, at: at(4), resets: at(5000)),
            #"{"type":"user","sessionId":"\#(session)","timestamp":"\#(stamp(at(5)))"}"#,
            "",
        ]
        let newest = LimitAnswer.newest(in: Data(lines.joined(separator: "\n").utf8))
        #expect(newest?.at == at(1) && newest?.session == session && newest?.version == "2.1.284")
        #expect(newest?.askedAt == nil, "no record it follows: when it was asked for isn't known")
        #expect(LimitAnswer.parse(line: Data(reply(at(1), #","isApiErrorMessage":true"#).utf8)) == nil)
    }
}

@Suite("Limit messages")
struct LimitHitTests {
    @Test func readsRefusalsAtTheFiveHourAndWeeklyLimitOnly() {
        let lines = [
            "{\"partial\":",
            limitLine(.fiveHour, at: at(0), resets: at(130)),
            #"{"type":"user","sessionId":"\#(session)","message":{"role":"user","content":"quotaLimits in words"}}"#,
            limitLine(.week, at: at(1), resets: at(5000)),
            limitLine(.fiveHour, at: at(2), resets: at(130)).replacingOccurrences(of: "\"rejected\",\"resetsAt", with: "\"allowed_warning\",\"resetsAt"),
            limitLine(.fiveHour, at: at(3), resets: at(130)).replacingOccurrences(of: "five_hour", with: "seven_day_opus"),
        ]
        let hits = LimitHit.hits(in: Data(lines.joined(separator: "\n").utf8))
        #expect(hits.map(\.kind) == [.fiveHour, .week])
        #expect(hits[0] == LimitHit(kind: .fiveHour, at: at(0), resetsAt: at(130), session: session, version: "2.1.284"))
    }

    @Test func aMessageCountsOnlyForTheOneWindowWhoseProcessHadTheSession() {
        let sightings = [
            LimitTracker.Sighting(session: session, window: "work", pid: 10, from: at(-60), lastSeen: at(30), version: "2.1.284"),
            LimitTracker.Sighting(session: session, window: "main", pid: 11, from: at(100), lastSeen: at(200)),
        ]
        var desktop = hit(.fiveHour, 10, resets: 130)
        desktop.version = "2.1.284"
        let late = hit(.fiveHour, 30.5, resets: 130)
        let tooLate = hit(.fiveHour, 40, resets: 130)
        let later = hit(.fiveHour, 150, resets: 300)
        var terminal = hit(.fiveHour, 10, resets: 130)
        terminal.entrypoint = "cli"
        var otherVersion = hit(.fiveHour, 10, resets: 130)
        otherVersion.version = "2.1.200"
        let result = LimitTracker.attribute([desktop, late, tooLate, later, terminal, otherVersion], to: sightings)
        #expect(result["work"] == [desktop, late])
        #expect(result["main"] == [later])
        // Credited only while the window has the account it had when the process was seen.
        var signed = sightings
        signed[0].account = Sandbox.accountA
        signed[1].account = Sandbox.accountA
        #expect(LimitTracker.attribute([desktop], to: signed, accounts: ["work": Sandbox.accountA])["work"] == [desktop])
        #expect(LimitTracker.attribute([desktop], to: signed, accounts: ["work": Sandbox.accountB]).isEmpty, "another account signed in since")
        #expect(LimitTracker.attribute([desktop], to: sightings, accounts: ["work": Sandbox.accountA]).isEmpty, "a sighting without an account")
        let overlapping = sightings + [LimitTracker.Sighting(session: session, window: "lab", pid: 12, from: at(120), lastSeen: at(160))]
        #expect(LimitTracker.attribute([later], to: overlapping).isEmpty, "two windows had it open: ambiguous, ignored")
    }

    @Test func recordsCopiedIntoABatonCopyStayWithTheSourceWindow() throws {
        let box = try Sandbox()
        let started = Date().addingTimeInterval(-3600)
        let original = try box.transcript(lines: [limitLine(.fiveHour, at: started, resets: started.addingTimeInterval(7200)), ""])
        let conversation = Conversation(kind: .code, sessionID: session, title: "t", folders: ["/repo"], lastActivity: started, transcript: original)
        let copy = try TranscriptFork.fork(conversation, claudeDir: box.paths.claudeDir)
        let tracker = LimitTracker()
        let engine = box.work.appending(path: "claude-code/2.1.284/claude.app/Contents/MacOS/claude").path
        let copyStarted = Date().addingTimeInterval(-60)
        tracker.liveProcesses = { _ in
            [
                LimitTracker.LiveProcess(
                    pid: 42, session: copy, startedAt: copyStarted, version: "2.1.284", cwd: "/repo", hostSessionID: "local_9", executable: engine)
            ]
        }
        let windows = [(id: "main", dataDir: box.main), (id: "work", dataDir: box.work)]
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: box.work.appending(path: "config.json"))
        #expect(tracker.hits(paths: box.paths, windows: windows).isEmpty, "the copy's old limit message happened in the source window")

        let copyFile = original.deletingLastPathComponent().appending(path: "\(copy).jsonl")
        let ends = try Data(contentsOf: copyFile).last == 0x0A
        let handle = try FileHandle(forWritingTo: copyFile)
        try handle.seekToEnd()
        let line = limitLine(.fiveHour, at: Date(), resets: Date().addingTimeInterval(3600), session: copy)
        try handle.write(contentsOf: Data(((ends ? "" : "\n") + line + "\n").utf8))
        try handle.close()
        #expect(tracker.hits(paths: box.paths, windows: windows)["work"]?.count == 1, "a new one in the copy is the destination's")
        #expect(tracker.lastWindows(paths: box.paths, windows: windows)[copy] == "work")
        #expect(box.exists(LimitTracker.file(box.paths)), "sightings are kept for when the process has ended")

        let later = LimitTracker()
        later.liveProcesses = { _ in [] }
        #expect(later.hits(paths: box.paths, windows: windows)["work"]?.count == 1, "remembered after the process ended")

        // A reply after the limit message, read in the same pass.
        let replied = Date().addingTimeInterval(1)
        let stamp = ISO8601DateFormatter.string(from: replied, timeZone: utc, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let append = try FileHandle(forWritingTo: copyFile)
        try append.seekToEnd()
        try append.write(
            contentsOf: Data(
                (#"{"type":"assistant","requestId":"req_9","sessionId":"\#(copy)","entrypoint":"claude-desktop","version":"2.1.284","timestamp":"\#(stamp)","message":{"model":"claude-opus-5-5"}}"#
                    + "\n").utf8))
        try append.close()
        let activity = tracker.activity(paths: box.paths, windows: windows, now: replied.addingTimeInterval(1))
        #expect(activity["work"]?.hits.count == 1 && activity["work"]?.answeredAt.map { abs($0.timeIntervalSince(replied)) < 0.01 } == true)

        // Another account signs in to the window: what the earlier one ran no longer counts for it.
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountA)"}"#, to: box.work.appending(path: "config.json"))
        #expect(later.hits(paths: box.paths, windows: windows).isEmpty)
    }
}

@Suite("Auto-continue entries")
struct AutoResumeTests {
    static let account = Sandbox.accountB

    static func config(_ bucket: String) -> String {
        """
        {
          "mcpServers": {},
          "preferences": {
            "zoom": 1.0,
            "epitaxyPrefs": {"autoResumeRateLimitOptIn.\(account)": true, "autoResumeRateLimit.\(account)": \(bucket), "other": [1, 2]}
          }
        }

        """
    }

    static let armed =
        #"{"local_1": {"resetsAt": 1790640600, "attempt": 0, "optedIn": true}, "local_2": {"resetsAt": 1790640600, "attempt": 3, "optedIn": true}}"#

    @Test func parsesPresentEmptyMissingAndMalformedBuckets() {
        let entries = AutoResume.entries(inConfig: Data(Self.config(Self.armed).utf8), account: Self.account)
        #expect(
            entries == [
                AutoResumeEntry(key: "local_1", resetsAt: Date(timeIntervalSince1970: 1_790_640_600)),
                AutoResumeEntry(key: "local_2", resetsAt: Date(timeIntervalSince1970: 1_790_640_600), attempt: 3),
            ])
        #expect(AutoResume.entries(inConfig: Data(Self.config("{}").utf8), account: Self.account) == [])
        #expect(AutoResume.entries(inConfig: Data(#"{"preferences":{"zoom":1}}"#.utf8), account: Self.account) == [], "no key")
        #expect(AutoResume.entries(inConfig: Data(Self.config(Self.armed).utf8), account: Sandbox.accountA) == [], "another account's key")
        #expect(AutoResume.entries(inConfig: Data(Self.config(#""oops""#).utf8), account: Self.account) == nil)
        #expect(AutoResume.entries(inConfig: Data("not json".utf8), account: Self.account) == nil)
        let now = Date(timeIntervalSince1970: 1_790_640_600)
        #expect(entries?.map { $0.isArmed(now: now) } == [true, false], "three attempts are Claude's limit")
        #expect(entries?[0].isArmed(now: now.addingTimeInterval(6 * 3600)) == false, "Claude drops an entry six hours late")
        let tried = AutoResumeEntry(key: "local_1", resetsAt: now, attempt: 1)
        #expect(tried.isArmed(now: now) && !tried.isArmed(now: now.addingTimeInterval(91)), "Claude has acted on it once its moment passed")
    }

    @Test func aTurnOffLeftForAnOpenWindowIsAppliedOnceItCloses() throws {
        let box = try Sandbox()
        let url = box.desktopConfig(box.work)
        try box.write(Self.config(Self.armed), to: url)
        let entry = try #require(AutoResume.entries(in: box.work, account: Self.account)?.first)
        let now = entry.resetsAt.addingTimeInterval(-600)
        let open = AutoResume(paths: box.paths, isRunning: { _ in true })
        try open.addPending(entry, window: "work", account: Self.account, now: now)
        #expect(open.applyPending(now: now).isEmpty && open.pending().count == 1, "still open: left as it is")
        #expect(box.read(url) == Self.config(Self.armed))

        let closed = AutoResume(paths: box.paths, isRunning: { _ in false })
        #expect(closed.applyPending(now: now) == ["work"])
        #expect(AutoResume.entries(in: box.work, account: Self.account)?.first?.optedIn == false)
        #expect(closed.pending().isEmpty && closed.changes().count == 1, "recorded, so doctor lists it")

        try closed.addPending(entry, window: "work", account: Self.account, now: now)
        #expect(closed.applyPending(now: now.addingTimeInterval(7 * 3600)).isEmpty && closed.pending().isEmpty, "Claude is done with it")
    }

    @Test func theSettingsFileLockIsSharedAndCanBeTakenAgainInside() throws {
        let box = try Sandbox()
        let lock = box.paths.stateDir.appending(path: "open.lock")
        let nested = try FileLock.withLock(lock, blocking: true) {
            try FileLock.withLock(lock, blocking: true) { 42 }
        }
        #expect(nested == .some(.some(42)), "a nested call doesn't wait for itself")
        try box.write(Self.config(Self.armed), to: box.desktopConfig(box.work))
        let entry = try #require(AutoResume.entries(in: box.work, account: Self.account)?.first)
        let turned = try FileLock.withLock(lock, blocking: true) {
            try AutoResume(paths: box.paths, isRunning: { _ in false }).turnOff(entry, window: "work", account: Self.account)
        }
        #expect(turned == true)
    }

    @Test func turnsOffOneEntryInAClosedWindowWithABackupAndCanUndoIt() throws {
        let box = try Sandbox()
        let url = box.desktopConfig(box.work)
        let original = Self.config(Self.armed)
        try box.write(original, to: url)
        let entry = try #require(AutoResume.entries(in: box.work, account: Self.account)?.first)
        let autoResume = AutoResume(paths: box.paths, isRunning: { _ in false })

        #expect(try autoResume.turnOff(entry, window: "work", account: Self.account))

        let written = try #require(box.read(url))
        #expect(
            written == original.replacingOccurrences(of: #""attempt": 0, "optedIn": true"#, with: #""attempt": 0, "optedIn": false"#),
            "one value, every other byte kept")
        #expect(written.contains("autoResumeRateLimitOptIn.\(Self.account)\": true"), "Claude's own choice is untouched")
        #expect(NativeForkCarry.files(under: box.paths.backupsDir).contains { $0.hasSuffix("Profiles/work/claude_desktop_config.json") })
        let change = try #require(autoResume.changes().first)
        #expect(change.entry == "local_1" && change.prior == "true" && change.window == "work")
        #expect(try autoResume.turnOff(entry, window: "work", account: Self.account) == false, "already off")

        #expect(try autoResume.undo(change))
        #expect(box.read(url) == original)
        #expect(autoResume.changes().isEmpty)
    }

    @Test func leavesAnOpenWindowsFileAlone() throws {
        let box = try Sandbox()
        let url = box.desktopConfig(box.work)
        try box.write(Self.config(Self.armed), to: url)
        let entry = try #require(AutoResume.entries(in: box.work, account: Self.account)?.first)
        let open = AutoResume(paths: box.paths, isRunning: { _ in true })
        #expect(throws: AutoResume.Failure.windowOpen("WORK")) { try open.turnOff(entry, window: "work", account: Self.account) }
        #expect(throws: AutoResume.Failure.windowOpen("(main)")) { try open.turnOff(entry, window: "main", account: Self.account) }
        #expect(box.read(url) == Self.config(Self.armed))
        #expect(!box.exists(box.paths.backupsDir))
    }

    @Test func handingOverTurnsOffTheSourceWindowsEntryForThatSessionOnly() throws {
        let box = try Sandbox()
        let manager = ProfileManager(paths: box.paths)
        try manager.registry.save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try box.write(#"{"lastKnownAccountUuid":"\#(Self.account)"}"#, to: box.work.appending(path: "config.json"))
        let cards = try box.pair(box.work, account: Self.account, org: org)
        try box.write(#"{"sessionId":"local_1","cliSessionId":"\#(session)"}"#, to: cards.appending(path: "local_1.json"))
        try box.write(#"{"sessionId":"local_2","cliSessionId":"99999999-2222-3333-4444-555555555555"}"#, to: cards.appending(path: "local_2.json"))
        let now = Date(timeIntervalSince1970: 1_790_640_000)
        let bucket =
            #"{"local_1": {"resetsAt": 1790640600, "attempt": 0, "optedIn": true}, "local_2": {"resetsAt": 1790640600, "attempt": 0, "optedIn": true}}"#
        try box.write(Self.config(bucket), to: box.desktopConfig(box.work))
        let conversation = Conversation(kind: .code, sessionID: session, title: "t", folders: [], lastActivity: now, transcript: box.root)

        var plans = [ContinuePlan(conversation: conversation, destination: "main", forks: true, model: nil)]
        manager.previewAutoResume(&plans, now: now)
        #expect(plans[0].autoResume == [.willTurnOff(label: "WORK")])
        #expect(manager.autoResumeOffer(for: [conversation], in: "main", now: now) == nil, "a closed window picks nothing up")
        manager.settleAutoResume(&plans, now: now)
        #expect(plans[0].autoResume == [.turnedOff(label: "WORK")])
        let entries = AutoResume.entries(in: box.work, account: Self.account) ?? []
        #expect(entries.map(\.optedIn) == [false, true], "the other session keeps its auto-continue")
        #expect(manager.autoResumeMatches(for: [session], excluding: "main", now: now).isEmpty)
    }
}

@Suite("Hand-over messages")
struct AutoResumeTextTests {
    let resets = Date(timeIntervalSince1970: 1_790_647_800)  // Tue 02:10 UTC

    @Test func theOpenWindowLineAndTheOfferSayWhenClaudeContinues() {
        let now = resets.addingTimeInterval(-3600)
        #expect(
            AutoResumeNote.stillOn(label: "WORK", resetsAt: resets).message(now: now, timeZone: utc, locale: gb)
                == "Claude WORK will continue this session by itself at 02:12 if it's on screen there, or when you next open this session there within 6 hours of the reset (Auto-continue when limits reset is on there). Baton turns that off once Claude WORK is closed: right away while the Baton app is running, otherwise when that window is next opened from Baton. To stop it sooner, untick that option on the limit message there; that turns auto-continue off for every session of that account in Claude WORK."
        )
        let later = AutoResumeNote.stillOn(label: "WORK", resetsAt: resets, copied: true).message(now: resets.addingTimeInterval(600), timeZone: utc)
        #expect(later.contains("by itself when you next open this session there, within 6 hours of the reset"))
        #expect(later.hasSuffix("Or archive the original session there: you continue in a copy."), "archiving only when the destination has a copy")
        #expect(!later.contains("quit"))
        #expect(
            AutoResumeOffer(label: "WORK", resetsAt: resets, sessions: [session], titles: ["Fix login"]).message(now: now, timeZone: utc, locale: gb)
                == "Claude WORK resets at 02:10 and picks “Fix login” up by itself at about 02:12 if it's on screen there, or when you next open it there within 6 hours."
        )
        #expect(
            AutoResumeOffer(label: "WORK", resetsAt: resets, titles: ["A", "B", "C"]).message(now: now, timeZone: utc, locale: gb).contains(
                "picks “A”, “B” and “C” up by itself at about 02:12 if they're on screen there"))
        #expect(
            AutoResumeOffer(label: "(main)", resetsAt: resets, titles: ["A"]).message(now: resets.addingTimeInterval(-3 * 3600), timeZone: utc, locale: gb)
                .hasPrefix("Claude (main) resets tomorrow at 02:10 and picks “A” up by itself tomorrow at about 02:12 if it's on screen"))
        let off = AutoResumeNote.turnedOff(label: "WORK").message()
        #expect(off.hasPrefix("Claude WORK was closed with Auto-continue when limits reset on") && off.contains("To turn it back on, tick that option"))
        #expect(LimitSchedule.roomAgain(status("work", limits: Limits(usage: nil), usage: nil)) == "Claude WORK has room again")
        #expect(LimitSchedule.roomAgain(status("main", limits: Limits(usage: nil), usage: nil)) == "Claude (main) has room again")
        #expect(
            ConversationIndex.passedNotice(label: "LAB", opened: 3, copies: 1, newSession: false)
                == "Baton passed to Claude LAB: opened 3 sessions there, 1 as a copy.")
        #expect(
            ConversationIndex.passedNotice(label: "LAB", opened: 1, copies: 0, newSession: true)
                == "Baton passed to Claude LAB: opened 1 session there, and started a new session.")
        #expect(ConversationIndex.passedNotice(label: "LAB", opened: 4, copies: 2, newSession: false).hasSuffix("4 sessions there, 2 as copies."))
        #expect(
            ConversationIndex.passedNotice(label: "(main)", opened: 0, copies: 0, newSession: true)
                == "Baton passed to Claude (main): started a new session there.", "every session was left to its own window")
    }

    @Test func theOfferComesOnlyWithinFifteenMinutesOfAnArmedEntryInAnOpenWindow() {
        let entry = AutoResumeEntry(key: "local_1", resetsAt: resets)
        #expect(AutoResumeOffer.applies(to: entry, isOpen: true, now: resets.addingTimeInterval(-15 * 60)))
        #expect(!AutoResumeOffer.applies(to: entry, isOpen: true, now: resets.addingTimeInterval(-15 * 60 - 1)))
        #expect(!AutoResumeOffer.applies(to: entry, isOpen: false, now: resets.addingTimeInterval(-60)), "a closed window doesn't continue it")
        #expect(!AutoResumeOffer.applies(to: entry, isOpen: true, now: resets.addingTimeInterval(90)), "its moment has passed")
        #expect(
            !AutoResumeOffer.applies(to: AutoResumeEntry(key: "local_1", resetsAt: resets, optedIn: false), isOpen: true, now: resets.addingTimeInterval(-60)))
    }
}

@Suite("Reset scheduling")
struct LimitScheduleTests {
    @Test func refreshesAtTheNextKnownResetAndAnnouncesOnlyKnownOnes() {
        let exact = status("work", limits: Limits(samples: [sample(0, fh: 100, sd: 40)], hits: [hit(.fiveHour, 1, resets: 130)]), usage: nil)
        let fallback = status("lab", limits: Limits(usage: Usage(fiveHour: 100, week: 10, sampledAt: base)), usage: nil)
        let free = status("main", limits: Limits(usage: Usage(fiveHour: 10, week: 10, sampledAt: base)), usage: nil)
        let all = [exact, fallback, free]
        #expect(LimitSchedule.nextRefresh(all, now: at(10)) == at(131.5))
        #expect(LimitSchedule.nextRefresh(all, now: at(140)) == nil)
        #expect(LimitSchedule.blocked(all, now: at(10)) == ["work": "acct-work", "lab": "acct-lab"])

        let blocked = ["work": "acct-work", "lab": "acct-lab"]
        #expect(LimitSchedule.freed(blockedBefore: blocked, all, now: at(131.5)).map(\.id) == ["work"])
        #expect(LimitSchedule.freed(blockedBefore: blocked, all, now: at(5 * 60)).map(\.id) == ["work"], "a sample growing old isn't announced")
        let dropped = status("lab", limits: Limits(samples: [sample(0, fh: 100, sd: 10), sample(60, fh: 2, sd: 10)]), usage: nil)
        #expect(LimitSchedule.freed(blockedBefore: blocked, [dropped], now: at(61)).map(\.id) == ["lab"], "a lower sample is")
        var switched = dropped
        switched.accountID = "acct-other"
        #expect(LimitSchedule.freed(blockedBefore: blocked, [switched], now: at(61)).isEmpty, "another account signed in: nothing reset")
    }
}

@Suite("Choosing where to continue by the binding limit")
struct BindingLimitRankingTests {
    let now = base

    func window(_ id: String, fh: Int, sd: Int, age: TimeInterval = 600, hits: [LimitHit] = []) -> ProfileStatus {
        let usage = Usage(fiveHour: fh, week: sd, sampledAt: now.addingTimeInterval(-age))
        return status(id, limits: Limits(samples: [UsageSample(at: usage.sampledAt, org: org, fiveHour: fh, week: sd)], hits: hits), usage: usage)
    }

    @Test func theHigherOfFiveHourAndWeeklyDecides() {
        let statuses = [window("busy", fh: 95, sd: 10), window("calm", fh: 0, sd: 30), window("rested", fh: 95, sd: 20, age: 6 * 3600)]
        #expect(DestinationRanking.ranked(statuses, now: now).map(\.id) == ["rested", "calm", "busy"], "a five-hour sample counts only for five hours")
        #expect(DestinationRanking.mostHeadroom(Array(statuses.prefix(2)), now: now) == "calm")
    }

    @Test func aWindowAtItsLimitIsLeftOutUntilItsResetPasses() {
        let out = window("out", fh: 100, sd: 10, hits: [hit(.fiveHour, -5, resets: 60)])
        let statuses = [out, window("calm", fh: 0, sd: 30)]
        #expect(DestinationRanking.ranked(statuses, now: now).map(\.id) == ["calm"])
        #expect(DestinationRanking.ranked(statuses, now: at(61.5)).map(\.id) == ["out", "calm"], "reset: its old sample no longer counts")
    }

    @Test func theSourceWindowIsNeverOfferedForItsOwnSession() throws {
        let running = Conversation(kind: .code, sessionID: session, title: "t", folders: ["/repo"], lastActivity: now, transcript: URL(fileURLWithPath: "/x"))
        var mine = running
        mine.runningIn = "work"
        mine.openIn = ["work"]
        let batch = ConversationIndex.continueAllBatch(in: "/repo", since: now.addingTimeInterval(-60), from: [mine, running], to: "work")
        #expect(batch.batch.count == 1 && batch.batch[0].runningIn == nil)

        let box = try Sandbox()
        let manager = ProfileManager(paths: box.paths)
        try manager.registry.save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        try box.write(#"{"lastKnownAccountUuid":"\#(Sandbox.accountB)"}"#, to: box.work.appending(path: "config.json"))
        let engine = box.work.appending(path: "claude-code/2.1.284/claude.app/Contents/MacOS/claude").path
        manager.limitTracker.liveProcesses = { _ in
            [LimitTracker.LiveProcess(pid: 7, session: session, startedAt: Date(), version: nil, cwd: "/repo", hostSessionID: nil, executable: engine)]
        }
        #expect(throws: ProfileError.sameWindow("WORK")) { try manager.plan([running], in: "work", mode: .fork) }
    }
}

@Suite("Waiting for a window that picks sessions up itself")
struct WaitSplitTests {
    /// Upper-case ids, as a card or a listing may give them; the offer keeps its ids in lower case.
    let sessions = (1...6).map {
        Conversation(
            kind: .code, sessionID: "AAAAAAA\($0)-BBBB-CCCC-DDDD-EEEEEEEEEEEE", title: "S\($0)", folders: ["/repo"], lastActivity: base,
            transcript: URL(fileURLWithPath: "/x"))
    }

    func offer(_ picked: [Conversation]) -> AutoResumeOffer {
        AutoResumeOffer(label: "WORK", resetsAt: at(10), sessions: Set(picked.map(\.sessionID)), titles: picked.map(\.title))
    }

    @Test func onlyTheSessionsItPicksUpAreLeftOut() {
        let one = ConversationIndex.splitForWait(sessions, offer: offer([sessions[2]]), alsoNewSession: false)
        #expect(one.continuing.map(\.title) == ["S1", "S2", "S4", "S5", "S6"] && one.leftOut.map(\.title) == ["S3"] && !one.stop)
        let all = ConversationIndex.splitForWait(sessions, offer: offer(sessions), alsoNewSession: false)
        #expect(all.continuing.isEmpty && all.leftOut.count == 6 && all.stop, "nothing goes ahead: only the offer to wait (the CLI exits 3)")
        let allAndNew = ConversationIndex.splitForWait(sessions, offer: offer(sessions), alsoNewSession: true)
        #expect(allAndNew.continuing.isEmpty && allAndNew.leftOut.count == 6 && !allAndNew.stop, "the new session still starts (exit 0)")
        let none = ConversationIndex.splitForWait(sessions, offer: nil, alsoNewSession: false)
        #expect(none.continuing.count == 6 && none.leftOut.isEmpty && !none.stop)
    }
}

@Suite("Naming windows and explaining reset times")
struct WindowWordingTests {
    @Test func theMainWindowIsClaudeMainInWhatBatonSays() throws {
        let box = try Sandbox()
        let manager = ProfileManager(paths: box.paths)
        try manager.registry.save([Profile(id: "work", label: "WORK", email: nil, color: "#1971C2")])
        #expect(manager.displayLabel(of: "main") == "(main)" && manager.displayLabel(of: "work") == "WORK")
        #expect(manager.label(of: "main") == "MAIN", "the label itself stays, as on the badge and in reports")
        #expect(throws: ProfileError.notSignedIn("(main)")) { try manager.plan([], in: "main") }
        #expect(ProfileError.notSignedIn("(main)").localizedDescription.hasPrefix("Sign in to Claude (main) first"))
        #expect(status("main", limits: Limits(usage: nil), usage: nil).displayLabel == "(main)")
    }

    /// A limit reached before Baton was watching has no reset time; the tooltip says why even with no note.
    @Test func theTooltipExplainsAMissingResetTime() {
        let reached = Limits(samples: [sample(0, fh: 100, sd: 40)])
        let open = status("work", limits: reached, usage: Usage(fiveHour: 100, week: 40, sampledAt: at(0)))
        #expect(open.limits.states.compactMap { LimitText.note($0, now: at(1)) }.isEmpty, "no note beside the meters")
        #expect(LimitText.columnHelp(open, now: at(1)).contains("They appear for limits reached while Baton is running"))
        let calm = status("work", limits: Limits(samples: [sample(0, fh: 10, sd: 40)]), usage: Usage(fiveHour: 10, week: 40, sampledAt: at(0)))
        #expect(LimitText.columnHelp(calm, now: at(1)).isEmpty)
        var closed = open
        closed.isRunning = false
        #expect(LimitText.columnHelp(closed, now: at(1)).hasSuffix("Open it to check: Claude records a new sample about 9 s after the window starts."))
    }
}

/// A transcript record as Claude Code writes it, with only what the walk from a reply to its request reads.
private func record(_ type: String, _ uuid: String, parent: String?, request: String? = nil, at date: Date, session: String = session) -> String {
    let stamp = ISO8601DateFormatter.string(from: date, timeZone: utc, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    let parentField = parent.map { #""\#($0)""# } ?? "null"
    let requestField = request.map { #","requestId":"\#($0)""# } ?? ""
    let message = type == "assistant" ? #","message":{"model":"claude-opus-5-5","role":"assistant"}"# : ""
    return
        #"{"type":"\#(type)","uuid":"\#(uuid)","parentUuid":\#(parentField)\#(requestField),"sessionId":"\#(session)","entrypoint":"claude-desktop","version":"2.1.284","timestamp":"\#(stamp)"\#(message)}"#
}

/// Seconds after 20:00 UTC on 28.09.
private func second(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

/// The same moment to the millisecond a transcript keeps.
private func same(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) < 0.001 } ?? false }

@Suite("Replies around a limit")
struct LimitReplyTests {
    /// 28.09, a real window at its five-hour limit (all times UTC): a sample at 100% at 20:04:41, another session
    /// refused at 20:04:43.8, then this session's replies at 20:04:48.5 and 20:04:49.6 to a request it sent after a tool
    /// result at 20:04:38.4, then its own refusal at 20:04:50.1.
    static let lines = [
        record("user", "u-1", parent: "a-0", at: second(278.434)),
        record("attachment", "t-1", parent: "u-1", at: second(278.439)),
        #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-28T20:04:45.000Z","sessionId":"\#(session)"}"#,
        record("assistant", "a-1", parent: "t-1", request: "req_A", at: second(288.521)),
        record("assistant", "a-2", parent: "a-1", request: "req_A", at: second(289.552)),
    ]
    static let samples = [sample(-3.17, fh: 95, sd: 16), UsageSample(at: second(281), org: org, fiveHour: 100, week: 17)]
    static let refusal = LimitHit(kind: .fiveHour, at: second(283.8), resetsAt: at(250), session: "77912f9a-0000-4000-8000-000000000000")

    @Test func aReplyStreamingWhenTheLimitHitDoesNotFreeTheWindow() throws {
        let answer = try #require(LimitAnswer.newest(in: Data((Self.lines.joined(separator: "\n") + "\n").utf8)))
        #expect(same(answer.at, second(289.552)) && same(answer.askedAt, second(278.439)), "asked for before the limit")
        let limits = Limits(samples: Self.samples, hits: [Self.refusal], answeredAt: answer.at, askedAt: answer.askedAt)
        #expect(limits.isAtLimit(now: second(289.9)) && !limits.fiveHour.resetByAnswer)
        // The turn that crossed 100% ends with that reply and nothing is refused after it.
        let quiet = Limits(samples: Self.samples, answeredAt: answer.at, askedAt: answer.askedAt)
        #expect(quiet.isAtLimit(now: second(300)) && quiet.fiveHour.percent == 100)
        let blockedBefore = LimitSchedule.blocked([status("ytw", limits: Limits(samples: Self.samples), usage: nil)], now: second(285))
        let now = [status("ytw", limits: quiet, usage: nil), status("calm", limits: Limits(samples: [sample(0, fh: 30, sd: 10)]), usage: nil)]
        #expect(LimitSchedule.freed(blockedBefore: blockedBefore, now, now: second(300)).isEmpty)
        #expect(DestinationRanking.ranked(now, now: second(300)).map(\.id) == ["calm"], "not offered as where to continue")
    }

    @Test func aReplyToARequestSentWellAfterTheLimitStillFreesIt() {
        let later = [
            record("user", "u-9", parent: "a-8", at: second(281 + 120)), record("assistant", "a-9", parent: "u-9", request: "req_B", at: second(281 + 125)),
        ]
        let answer = LimitAnswer.newest(in: Data((Self.lines + later).joined(separator: "\n").utf8))
        #expect(same(answer?.askedAt, second(401)))
        let limits = Limits(samples: Self.samples, hits: [Self.refusal], answeredAt: answer?.at, askedAt: answer?.askedAt)
        #expect(!limits.isAtLimit(now: second(410)) && limits.fiveHour.resetByAnswer)
    }

    /// Baton reads a transcript every few seconds: the request's own record is in one read, its reply in the next.
    @Test func aReplyIsFollowedBackIntoTheEarlierRead() throws {
        let box = try Sandbox()
        let url = try box.transcript(lines: Array(Self.lines.prefix(3)) + [""])
        let tracker = LimitTracker()
        #expect(tracker.scan(url).answer == nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.lines[3] + "\n").utf8))
        try handle.close()
        #expect(same(tracker.scan(url).answer?.askedAt, second(278.439)))
        let again = try FileHandle(forWritingTo: url)
        try again.seekToEnd()
        try again.write(contentsOf: Data((Self.lines[4] + "\n").utf8))
        try again.close()
        let answer = tracker.scan(url).answer
        #expect(same(answer?.at, second(289.552)) && same(answer?.askedAt, second(278.439)))
    }

    @Test func roomAgainIsAnnouncedOnlyAfterAMinuteStillFree() {
        let blocked = status("work", limits: Limits(samples: [sample(0, fh: 100, sd: 10)]), usage: nil)
        let free = status("work", limits: Limits(samples: [sample(0, fh: 100, sd: 10), sample(2, fh: 3, sd: 10)]), usage: nil)
        var watch = RoomAgainWatch()
        #expect(watch.update([blocked], now: at(1)).blocked == ["work"])
        #expect(watch.update([free], now: at(2)).announce.isEmpty && watch.nextCheck == at(3), "free for the first time: wait")
        #expect(watch.update([blocked], now: at(2.5)).announce.isEmpty && watch.nextCheck == nil, "blocked again: never announced")
        #expect(watch.update([free], now: at(3)).announce.isEmpty)
        #expect(watch.update([free], now: at(3.5)).announce.isEmpty)
        #expect(watch.update([free], now: at(4)).announce.map(\.id) == ["work"])
        #expect(watch.update([free], now: at(5)).announce.isEmpty, "once")
        var switched = free
        switched.accountID = "acct-other"
        var other = RoomAgainWatch()
        _ = other.update([blocked], now: at(1))
        _ = other.update([free], now: at(2))
        #expect(other.update([switched], now: at(4)).announce.isEmpty, "another account signed in meanwhile")
    }
}

@Suite("Certainly reset limits")
struct CertainResetTests {
    @Test func aReserveWhoseLimitsHaveCertainlyResetRanksAheadOfANearlyFullWindow() {
        let old = base.addingTimeInterval(-8 * 86_400)
        let reserveUsage = Usage(fiveHour: 100, week: 100, sampledAt: old)
        let reserve = status("reserve", limits: Limits(usage: reserveUsage), usage: reserveUsage)
        #expect(LimitText.summary(reserve.limits, usage: reserveUsage, now: base) == "5h reset · week reset · as of 8d ago")
        let busyUsage = Usage(fiveHour: 95, week: 20, sampledAt: base.addingTimeInterval(-60))
        let busy = status("busy", limits: Limits(usage: busyUsage), usage: busyUsage)
        #expect(DestinationRanking.ranked([busy, reserve], now: base).map(\.id) == ["reserve", "busy"])
        let weekOld = Usage(fiveHour: 10, week: 90, sampledAt: old)
        #expect(Limits(usage: weekOld).load(now: base) == 0, "a weekly sample older than a week: that week is over")
        let fresh = Usage(fiveHour: 10, week: 90, sampledAt: base.addingTimeInterval(-3 * 86_400))
        #expect(Limits(usage: fresh).load(now: base) == 90, "within its week a weekly sample counts however old")
    }

    /// Reached by a sample, with an estimate from an older weekly hit; the window is closed and the estimate has
    /// passed: opening it is the one way to know.
    @Test func aClosedWindowPastItsEstimateSaysToOpenIt() {
        let samples = [sample(-10 * 24 * 60, fh: 5, sd: 50), sample(-5 * 24 * 60, fh: 5, sd: 10), sample(0, fh: 20, sd: 100)]
        let limits = Limits(samples: samples, hits: [hit(.week, -7 * 24 * 60 - 60, resets: -7 * 24 * 60 + 33 * 60)])
        #expect(limits.week.reset == LimitReset(at: at(33 * 60), source: .estimate) && limits.week.sampleOnly)
        var closed = status("work", limits: limits, usage: Usage(fiveHour: 20, week: 100, sampledAt: base))
        closed.isRunning = false
        #expect(LimitText.checkHint(closed, now: at(60)) == nil, "the estimate is still ahead")
        let past = at(35 * 60)
        #expect(limits.isAtLimit(now: past) && LimitText.atLimit(limits, now: past, timeZone: utc, locale: gb).contains("may have reset"))
        #expect(LimitText.checkHint(closed, now: past) != nil)
        closed.isRunning = true
        #expect(LimitText.checkHint(closed, now: past) == nil, "an open window samples by itself")
    }

    /// Why a drop from 100% in the first minutes of an auto-continue entry's window doesn't cancel the entry: right
    /// after a window starts Claude may still report the previous window's value. Here the previous window ended at its
    /// limit, the new one's real usage was 30% at +17 min, and the window then hit the limit again and closed.
    @Test func aPreviousWindowsHundredLaggingIntoTheNextKeepsTheEntry() {
        let samples = [sample(-1, fh: 95, sd: 40), sample(2, fh: 100, sd: 41), sample(17, fh: 30, sd: 42)]
        let limits = Limits(samples: samples, autoResume: [at(300)])
        #expect(limits.isAtLimit(now: at(200)) && limits.fiveHour.reset == LimitReset(at: at(300), source: .exact))
    }

    /// The limit reached eight minutes into the entry's window, then reset early while the window sat idle: Claude's
    /// latest sample reads 0%, and Baton no longer holds the window back until the entry's reset.
    @Test func anEarlyResetAfterAHitInTheFirstTenMinutes() {
        let samples = [sample(-1, fh: 20, sd: 12), sample(8, fh: 100, sd: 12), sample(60, fh: 0, sd: 12)]
        let limits = Limits(samples: samples, autoResume: [at(300)])
        #expect(!limits.isAtLimit(now: at(61)) && limits.fiveHour.phase(now: at(61)) == .below)
        #expect(LimitText.describe(limits.fiveHour, now: at(61)) == "5h 0%")
        let ready = status("work", limits: limits, usage: Usage(fiveHour: 0, week: 12, sampledAt: at(60)))
        #expect(DestinationRanking.ranked([ready], now: at(61)).map(\.id) == ["work"])
    }
}
