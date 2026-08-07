import Foundation

/// SMC fan mode: 0 = automatic, 1 = manual, anything else = system/thermal
/// manager holds the fan (mode 3 on recent firmware).
public enum FanMode: String, Equatable {
    case auto = "auto"
    case manual = "manual"
    case system = "system"

    public static func fromRaw(_ v: UInt8) -> FanMode {
        switch v {
        case 0: return .auto
        case 1: return .manual
        default: return .system
        }
    }
}

/// One fan as discovered on the SMC.
public struct Fan {
    public let index: Int
    public let name: String
    public var min: Float
    public var max: Float
    public var actual: Float
    public var target: Float
    public var mode: FanMode
    /// The mode key actually present on this machine (`F{i}Md`, or the
    /// lowercase `F{i}md` variant some M5 firmware uses).
    public let mdKey: String

    public init(index: Int, name: String, min: Float, max: Float, actual: Float,
                target: Float, mode: FanMode, mdKey: String) {
        self.index = index
        self.name = name
        self.min = min
        self.max = max
        self.actual = actual
        self.target = target
        self.mode = mode
        self.mdKey = mdKey
    }
}

public enum FanDiscovery {
    /// `F{i}{suffix}`, e.g. `F0Ac`.
    public static func keyName(_ index: Int, _ suffix: String) -> String {
        "F\(index)\(suffix)"
    }

    /// Probes for the fan's mode key: `F{i}Md` first, then lowercase `F{i}md`
    /// (M5-generation firmware).
    public static func probeModeKey(_ smc: SMC, index: Int) -> String {
        let primary = keyName(index, "Md")
        if smc.exists(primary) {
            return primary
        }
        let lower = keyName(index, "md")
        if smc.exists(lower) {
            return lower
        }
        return primary
    }

    /// Fan name from `F{i}ID` when available ("ch8*"), else "Fan i".
    public static func fanName(_ smc: SMC, index: Int) -> String {
        let key = keyName(index, "ID")
        if let v = try? smc.read(key), v.typeString == "ch8*" {
            let s = String(decoding: v.bytes.prefix(Int(v.size)), as: UTF8.self)
            if !s.isEmpty {
                return s
            }
        }
        return "Fan \(index)"
    }

    /// Reads an RPM key, decoding by its runtime type.
    public static func readRPM(_ smc: SMC, key: String) -> Float? {
        guard let v = try? smc.read(key), let f = v.asFloat(), f.isFinite else {
            return nil
        }
        return f
    }

    public static func readMode(_ smc: SMC, fan: Fan) -> FanMode {
        guard let v = try? smc.read(fan.mdKey), let raw = v.asUInt8() else {
            return .auto
        }
        return FanMode.fromRaw(raw)
    }

    /// Forces (or releases) manual mode for a fan.
    ///
    /// Apple Silicon: write the `F{i}Md` mode key directly.
    /// Intel (implemented but untested): set/clear the fan's bit in the `FS! `
    /// force bitmask.
    public static func writeMode(_ smc: SMC, fan: Fan, manual: Bool) throws {
        if SMC.isAppleSilicon {
            try smc.write(fan.mdKey, [manual ? 1 : 0])
        } else {
            var bits: UInt32 = 0
            if let v = try? smc.read("FS! "), let b = v.asUInt32() {
                bits = b
            }
            if manual {
                bits |= 1 << fan.index
            } else {
                bits &= ~(1 << fan.index)
            }
            let data = withUnsafeBytes(of: bits.bigEndian) { Array($0) }
            try smc.write("FS! ", data)
        }
    }

    /// Encodes an RPM into the wire bytes for the key's runtime type:
    /// "flt " → IEEE-754 float (LE on Apple Silicon, BE on Intel),
    /// "fpe2" → 14.2 fixed point BE, clamped to 0…16383.
    public static func encodeRPM(dataType: UInt32, rpm: Float) throws -> [UInt8] {
        switch fourccString(dataType) {
        case "flt ":
            let raw = rpm.bitPattern
            if SMC.isAppleSilicon {
                return withUnsafeBytes(of: raw.littleEndian) { Array($0) }
            } else {
                return withUnsafeBytes(of: raw.bigEndian) { Array($0) }
            }
        case "fpe2":
            let scaled = UInt16(min(max(rpm, 0), 16383) * 4)
            return withUnsafeBytes(of: scaled.bigEndian) { Array($0) }
        default:
            throw FandError.badData
        }
    }

    /// Clamps a target into the firmware-reported min/max range.
    public static func clampedTarget(_ rpm: Float, min: Float, max: Float) -> Float {
        Swift.min(Swift.max(rpm, min), max)
    }

    /// Discovers all fans: `FNum` count, per-fan min/max/name, mode key probe.
    /// Returns an empty array on fanless Macs.
    public static func discover(_ smc: SMC) throws -> [Fan] {
        var count: UInt32 = 0
        if let v = try? smc.read("FNum") {
            count = v.asUInt32() ?? v.asUInt32LE() ?? 0
        }
        guard count > 0, count < 64 else {
            return []
        }
        var fans: [Fan] = []
        for i in 0..<Int(count) {
            var min = readRPM(smc, key: keyName(i, "Mn")) ?? 0
            var max = readRPM(smc, key: keyName(i, "Mx")) ?? 6000
            if !(min >= 0 && min < max) {
                min = 0
                max = 6000
            }
            fans.append(Fan(
                index: i,
                name: fanName(smc, index: i),
                min: min,
                max: max,
                actual: 0,
                target: 0,
                mode: .auto,
                mdKey: probeModeKey(smc, index: i)
            ))
        }
        for i in fans.indices {
            refresh(smc, &fans[i])
        }
        return fans
    }

    /// Refreshes actual RPM, target RPM and mode for one fan.
    public static func refresh(_ smc: SMC, _ fan: inout Fan) {
        if let actual = readRPM(smc, key: keyName(fan.index, "Ac")) {
            fan.actual = actual
        }
        if let target = readRPM(smc, key: keyName(fan.index, "Tg")) {
            fan.target = target
        }
        fan.mode = readMode(smc, fan: fan)
    }

    /// Writes a target RPM to `F{i}Tg` (encoding by the key's runtime type).
    public static func writeTarget(_ smc: SMC, fan: Fan, rpm: Float) throws {
        let key = keyName(fan.index, "Tg")
        let info = try smc.keyInfo(fourcc(key))
        let data = try encodeRPM(dataType: info.dataType, rpm: rpm)
        try smc.write(key, data)
    }
}
