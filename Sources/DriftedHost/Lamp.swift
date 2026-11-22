import Foundation
import DriftedKit

/// The lamp as the user has it: colour and light mode. Drifted keeps this itself (switches.json), because the
/// table can lose it: it has been found back on its stock first palette colour (`c0`, a cyan-green) with our
/// "Temp" entry gone, brightness untouched (docs/failure-modes.md). It is what a season hands back when it
/// ends, and what goes back on the lamp when the table has fallen back to its default.
public struct LampColor: Codable, Equatable {
    /// The palette entry: "Temp" for a custom colour (`color` says which), otherwise a palette name.
    public var colorName: String
    /// `#rrggbb`.
    public var color: String
    public var shifting: Bool
    public var shiftSeconds: UInt16
    public var breathing: Bool

    public init(colorName: String, color: String, shifting: Bool = false, shiftSeconds: UInt16 = 0, breathing: Bool = false) {
        self.colorName = colorName; self.color = color; self.shifting = shifting
        self.shiftSeconds = shiftSeconds; self.breathing = breathing
    }

    /// A fixed custom colour.
    public static func fixed(_ hex: String) -> LampColor {
        LampColor(colorName: "Temp", color: (hex.hasPrefix("#") ? hex : "#" + hex).lowercased())
    }

    init(_ s: TableState) {
        self.init(colorName: s.colorName, color: s.color, shifting: s.shifting, shiftSeconds: s.shiftSeconds, breathing: s.breathing)
    }

    var isCustom: Bool { colorName == "Temp" || colorName.isEmpty }

    var summary: String {
        (isCustom ? color : "\(colorName) \(color)") + (shifting ? ", shifting" : "") + (breathing ? ", breathing" : "")
    }
}

public enum LampRules {
    public enum Action: Equatable {
        case nothing
        /// The table shows something else that somebody chose (the HoMedics app): it becomes the user's lamp.
        case adopt
        /// The table has fallen back to its default: put `wanted` back.
        case restore
    }

    /// The table's stock first palette colour. A custom colour takes this entry's place ("Temp"), so seeing it
    /// again where a custom colour was means the table lost the setting.
    public static let fallbackName = "c0"

    public static func sameColor(_ a: String, _ b: String) -> Bool {
        guard let x = ScheduleRules.parseColor(a), let y = ScheduleRules.parseColor(b) else { return a.lowercased() == b.lowercased() }
        return abs(Int(x.0) - Int(y.0)) <= 3 && abs(Int(x.1) - Int(y.1)) <= 3 && abs(Int(x.2) - Int(y.2)) <= 3
    }

    /// The table shows `wanted`. In shifting mode the colour moves, so only the mode is compared.
    public static func shows(_ table: LampColor, _ wanted: LampColor) -> Bool {
        guard table.shifting == wanted.shifting, table.breathing == wanted.breathing else { return false }
        if wanted.shifting { return true }
        if wanted.isCustom { return table.isCustom && sameColor(table.color, wanted.color) }
        return table.colorName == wanted.colorName
    }

    /// What to do about the lamp the table reports. `wanted`: the season's colour while one is on the lamp,
    /// otherwise the user's (nil: none remembered yet). In a season nothing is adopted: the table is showing the
    /// season's colour, not the user's.
    public static func decide(table: LampColor, wanted: LampColor?, inSeason: Bool) -> Action {
        guard let wanted else { return inSeason ? .nothing : .adopt }
        if shows(table, wanted) { return .nothing }
        if table.colorName == fallbackName, !table.shifting, wanted.colorName != fallbackName { return .restore }
        return inSeason ? .nothing : .adopt
    }
}

extension Daemon {
    /// The colour a season has on the lamp right now, if one does.
    var seasonLampColor: LampColor? {
        guard let name = scheduleState.lampSeason,
              let season = schedule.seasons.first(where: { $0.name == name }), !season.colors.isEmpty else { return nil }
        return .fixed(season.colors[scheduleState.colorIndex % season.colors.count])
    }

    /// Sends lamp packets as a job, and has `lampWatch` wait for the table's word on them before it judges.
    @discardableResult
    func lampCommand(_ kind: String, _ packets: [Packet]) -> Job {
        lampPending += 1
        return enqueue(kind) { _ in
            defer { self.lampPending -= 1; self.lampCommandAt = Date() }
            if self.viaRelayJob {
                try await self.relayRun(kind, packets.map { .init(.send($0)) })
                return nil
            }
            for p in packets { try await self.table.send(p) }
            return nil
        }
    }

    /// Puts `lamp` on the table at the lamp's current level.
    func lampSend(_ lamp: LampColor, _ kind: String) {
        let level = max(0.01, switches.lampLevel)
        var packets: [Packet] = []
        if lamp.isCustom, let (r, g, b) = ScheduleRules.parseColor(lamp.color) {
            packets += [Command.previewColor(r: r, g: g, b: b), Command.selectColor("Temp")]
        } else {
            packets.append(Command.selectColor(lamp.colorName))
        }
        packets += [Command.lightMode(shifting: lamp.shifting, shiftTime: lamp.shiftSeconds, breathing: lamp.breathing, brightness: level),
                    Command.brightness(level)]
        lampCommand(kind, packets)
    }

    /// A colour or light mode set through /settings is the user's lamp from now on (during a season: what comes
    /// back after it).
    func lampNoteSettings(_ s: SettingsInput) {
        guard s.color != nil || s.shifting != nil || s.breathing != nil else { return }
        let inSeason = scheduleState.lampSeason != nil
        guard var mine = s.color.map(LampColor.fixed) ?? switches.lampColor ?? (inSeason ? nil : table.tableState.map(LampColor.init))
        else { return }
        // As the table gets it: 0x11/4 sets the whole mode, and what isn't asked for is off.
        mine.shifting = s.shifting ?? false
        mine.breathing = s.breathing ?? false
        if let t = s.shiftSeconds { mine.shiftSeconds = UInt16(clamping: t) }
        if mine != switches.lampColor { log("lamp: yours is now \(mine.summary)") }
        rememberLamp(mine, owed: true)
        lampResends = 0
    }

    /// Sends the lamp when the table doesn't show what it should: at once the first time, then (while the table
    /// still hasn't shown it) at most twice more, ten minutes apart.
    private func lampResend(_ lamp: LampColor, now: Date, _ why: String) {
        guard lampResends < 3 else {
            if lampResends == 3 {
                lampResends += 1
                log("lamp: sent three times and the table still doesn't show \(lamp.summary); leaving it until a colour is set")
            }
            return
        }
        guard lampResends == 0 || now.timeIntervalSince(lampResentAt) > 600 else { return }
        lampResends += 1
        lampResentAt = now
        log("lamp: \(why)")
        lampSend(lamp, "lamp restore")
    }

    /// Runs every few seconds. Looks at each new state from the table once: follows a lamp somebody chose
    /// elsewhere, and puts the user's (in a season: the season's) back when the table has fallen back to its
    /// default. Leaves a lamp that's switched off alone, and waits out lamp commands of our own.
    func lampWatch(now: Date = Date()) {
        if switches.lampColor == nil, let old = scheduleState.lamp {   // from before Drifted kept it in switches.json
            rememberLamp(old)
        }
        guard switches.lamp, tableUsable, !liveRunning, !jobRunning, lampPending == 0,
              let s = table.tableState, let at = lastStateAt, at != lampJudgedAt, s.brightness > 0, !s.color.isEmpty else { return }
        // A state from before a lamp command of ours ended says nothing about it: live, the first ones after it
        // can still show the old lamp; through relay jobs, states arrive with the job that fetched them.
        guard at.timeIntervalSince(lampCommandAt) > (viaRelayJob ? 0 : 3) else { return }
        lampJudgedAt = at
        let shown = LampColor(s)
        if scheduleState.lampSeason != nil {
            // A season's colour is on the lamp: nothing the table shows is the user's choice. (No colour: the
            // season has just left the schedule, and syncSeasonLamp is about to hand the lamp back.)
            guard let season = seasonLampColor else { return }
            if LampRules.shows(shown, season) {
                lampResends = 0
            } else if LampRules.decide(table: shown, wanted: season, inSeason: true) == .restore {
                lampResend(season, now: now, "the table is back on its default colour (\(shown.summary)); putting the "
                           + "\(scheduleState.lampSeason ?? "season") colour \(season.summary) back")
            }
            return
        }
        if switches.lampOwed, let mine = switches.lampColor {
            // We sent the user's lamp (after a season, after a fallback, from /settings): until the table shows
            // it, what it shows instead (the season's colour, say) mustn't be taken for the user's.
            if LampRules.shows(shown, mine) {
                setLampOwed(false)
                lampResends = 0
            } else {
                lampResend(mine, now: now, "the table shows \(shown.summary), not yours (\(mine.summary)); sending it again")
            }
            return
        }
        switch LampRules.decide(table: shown, wanted: switches.lampColor, inSeason: false) {
        case .nothing:
            lampResends = 0
        case .adopt:
            log(switches.lampColor == nil ? "lamp: remembering \(shown.summary) as yours"
                                          : "lamp: the table shows \(shown.summary), set somewhere else; that's yours now")
            rememberLamp(shown)
            lampResends = 0
        case .restore:
            guard let mine = switches.lampColor else { return }
            setLampOwed(true)
            lampResend(mine, now: now, "the table is back on its default colour (\(shown.summary)); putting yours, \(mine.summary), back")
        }
    }
}
