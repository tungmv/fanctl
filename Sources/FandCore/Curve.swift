import Foundation

/// One (temperature, RPM) breakpoint of a fan curve.
public struct CurvePoint: Codable, Equatable, Sendable {
    public let temp: Float
    public let rpm: Float

    public init(temp: Float, rpm: Float) {
        self.temp = temp
        self.rpm = rpm
    }
}

/// A temperature→RPM fan curve: a sorted list of breakpoints with linear
/// interpolation between them. Below the first breakpoint the first RPM
/// applies; above the last, the last RPM applies.
///
/// `sensor` selects the temperature source: `"hottest"` (default),
/// `"avg"`, or a specific SMC sensor key (e.g. `"Tp05P"`).
public struct FanCurve: Codable, Equatable, Sendable {
    public let points: [CurvePoint]
    public let sensor: String

    /// Sorted by temperature; ≥ 2 points; strictly increasing temperatures;
    /// non-negative RPM.
    public init(points: [CurvePoint], sensor: String) throws {
        let cleaned = sensor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw FandError.invalidInput("a curve needs a sensor (hottest, avg, or an SMC key)")
        }
        guard points.count >= 2 else {
            throw FandError.invalidInput("a curve needs at least 2 points (temp:rpm)")
        }
        let sorted = points.sorted { $0.temp < $1.temp }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            guard a.temp < b.temp else {
                throw FandError.invalidInput("curve temperatures must be strictly increasing")
            }
        }
        for p in sorted {
            guard p.rpm.isFinite, p.rpm >= 0 else {
                throw FandError.invalidInput("curve RPM values must be non-negative")
            }
        }
        self.points = sorted
        self.sensor = cleaned
    }

    /// Interpolated target RPM for a temperature.
    public func target(forTemp t: Float) -> Float {
        guard t.isFinite else { return points[0].rpm }
        if t <= points[0].temp { return points[0].rpm }
        if t >= points[points.count - 1].temp { return points[points.count - 1].rpm }
        for (a, b) in zip(points, points.dropFirst()) where t >= a.temp && t <= b.temp {
            let f = (t - a.temp) / (b.temp - a.temp)
            return a.rpm + f * (b.rpm - a.rpm)
        }
        return points[points.count - 1].rpm
    }

    /// Resolves the sensor selection against a temperatures snapshot.
    public func sensorValue(in temps: TempsSnapshot) -> Float? {
        switch sensor {
        case "hottest":
            return temps.hottest?.temp
        case "avg":
            return temps.avg
        default:
            return temps.sensors.first { $0.key == sensor }?.temp
        }
    }

    /// Short human-readable form: "50:1500 60:2500 70:4000".
    public var summary: String {
        points.map { "\(Int($0.temp)):\(Int($0.rpm))" }.joined(separator: " ")
    }
}

/// Persistence for active curves. Stored as JSON at `/var/db/fand/curve.json`
/// (requires root, matching the daemon); a curve set once survives daemon
/// restarts, while pins remain memory-only by design.
public struct CurveStore {
    public static let defaultPath = "/var/db/fand/curve.json"

    public let path: String

    public init(path: String = CurveStore.defaultPath) {
        self.path = path
    }

    struct StoredCurve: Codable, Equatable {
        let fan: Int
        let curve: FanCurve
    }

    public func load() -> [Int: FanCurve] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([StoredCurve].self, from: data) else {
            return [:]
        }
        var result: [Int: FanCurve] = [:]
        for entry in decoded {
            result[entry.fan] = entry.curve
        }
        return result
    }

    /// Persists the active curves (fan index → curve). Returns false when the
    /// file could not be written (e.g. daemon not running as root).
    @discardableResult
    public func save(_ curves: [Int: FanCurve]) -> Bool {
        let url = URL(fileURLWithPath: path)
        do {
            if curves.isEmpty {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                return true
            }
            let stored = curves.sorted { $0.key < $1.key }.map { StoredCurve(fan: $0.key, curve: $0.value) }
            let data = try JSONEncoder().encode(stored)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
