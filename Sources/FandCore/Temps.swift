import Foundation

public struct TempReading: Equatable {
    public let key: String
    public let temp: Float

    public init(key: String, temp: Float) {
        self.key = key
        self.temp = temp
    }
}

public struct TempsSnapshot {
    public let avg: Float
    public let hottest: (key: String, temp: Float)?
    public let sensors: [TempReading]

    public init(avg: Float, hottest: (key: String, temp: Float)?, sensors: [TempReading]) {
        self.avg = avg
        self.hottest = hottest
        self.sensors = sensors
    }
}

public enum Temps {
    /// Plausibility filter used during discovery and refresh, so a garbage
    /// reading (or an unrelated key) never poisons the average.
    public static func isPlausible(_ t: Float) -> Bool {
        (15.0...115.0).contains(t)
    }

    /// Discovers temperature-sensor keys: any key starting with "T" whose
    /// runtime type is "flt " or "sp78" with a plausible current reading.
    public static func discover(_ smc: SMC) -> [String] {
        guard let count = try? smc.keyCount(), count > 0, count < 100_000 else {
            return []
        }
        var keys: [String] = []
        for i in 0..<count {
            guard let k = try? smc.keyAt(i), k.hasPrefix("T") else { continue }
            guard let v = try? smc.read(k), v.typeString == "flt " || v.typeString == "sp78" else {
                continue
            }
            if let t = v.asFloat(), isPlausible(t) {
                keys.append(k)
            }
        }
        return keys
    }

    /// Refreshes all discovered sensors and computes avg + hottest.
    public static func refresh(_ smc: SMC, keys: [String]) -> TempsSnapshot {
        var readings: [TempReading] = []
        for k in keys {
            if let v = try? smc.read(k), let t = v.asFloat(), t.isFinite, isPlausible(t) {
                readings.append(TempReading(key: k, temp: t))
            }
        }
        let avg = readings.isEmpty ? 0 : readings.reduce(0) { $0 + $1.temp } / Float(readings.count)
        let hottest = readings.max { $0.temp < $1.temp }
        return TempsSnapshot(
            avg: avg,
            hottest: hottest.map { (key: $0.key, temp: $0.temp) },
            sensors: readings
        )
    }
}
