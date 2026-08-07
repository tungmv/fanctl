import Testing
import Foundation
@testable import FandCore

@Suite struct CurveTests {

    private func curve(_ points: [(Float, Float)], sensor: String = "hottest") throws -> FanCurve {
        try FanCurve(points: points.map { CurvePoint(temp: $0.0, rpm: $0.1) }, sensor: sensor)
    }

    // MARK: interpolation

    @Test func interpolationBelowFirstPoint() throws {
        let c = try curve([(50, 1500), (70, 3500)])
        #expect(c.target(forTemp: 30) == 1500)
        #expect(c.target(forTemp: 50) == 1500)
    }

    @Test func interpolationAboveLastPoint() throws {
        let c = try curve([(50, 1500), (70, 3500)])
        #expect(c.target(forTemp: 90) == 3500)
        #expect(c.target(forTemp: 70) == 3500)
    }

    @Test func interpolationLinear() throws {
        let c = try curve([(50, 1500), (70, 3500)])
        #expect(c.target(forTemp: 60) == 2500)
        #expect(c.target(forTemp: 55) == 2000)
        #expect(c.target(forTemp: 65) == 3000)
    }

    @Test func interpolationMultiPoint() throws {
        let c = try curve([(40, 1000), (55, 2000), (80, 5000)])
        #expect(c.target(forTemp: 40) == 1000)
        #expect(c.target(forTemp: 47.5) == 1500)
        #expect(c.target(forTemp: 55) == 2000)
        #expect(c.target(forTemp: 67.5) == 3500)
        #expect(c.target(forTemp: 80) == 5000)
        #expect(c.target(forTemp: 100) == 5000)
    }

    @Test func interpolationNaN() throws {
        let c = try curve([(50, 1500), (70, 3500)])
        #expect(c.target(forTemp: .nan) == 1500)  // degrades to the minimum RPM
    }

    // MARK: validation

    @Test func validationRejectsFewerThanTwoPoints() {
        #expect(throws: FandError.self) {
            _ = try FanCurve(points: [CurvePoint(temp: 50, rpm: 1500)], sensor: "hottest")
        }
        #expect(throws: FandError.self) {
            _ = try FanCurve(points: [], sensor: "hottest")
        }
    }

    @Test func validationRejectsDuplicateTemps() {
        // Equal temperatures would divide by zero during interpolation.
        #expect(throws: FandError.self) {
            _ = try FanCurve(points: [
                CurvePoint(temp: 50, rpm: 1500),
                CurvePoint(temp: 50, rpm: 3500),
            ], sensor: "hottest")
        }
    }

    @Test func validationRejectsNegativeRPM() {
        #expect(throws: FandError.self) {
            _ = try FanCurve(points: [
                CurvePoint(temp: 50, rpm: -100),
                CurvePoint(temp: 70, rpm: 3500),
            ], sensor: "hottest")
        }
    }

    @Test func validationRejectsEmptySensor() {
        #expect(throws: FandError.self) {
            _ = try FanCurve(points: [
                CurvePoint(temp: 50, rpm: 1500),
                CurvePoint(temp: 70, rpm: 3500),
            ], sensor: "   ")
        }
    }

    @Test func unsortedPointsAreSortedOnInit() throws {
        let c = try curve([(70, 3500), (50, 1500), (60, 2500)])
        #expect(c.points.map(\.temp) == [50, 60, 70])
        #expect(c.target(forTemp: 60) == 2500)
    }

    // MARK: sensor resolution

    @Test func sensorResolution() throws {
        let temps = TempsSnapshot(
            avg: 52.5,
            hottest: (key: "Tp05P", temp: 71.3),
            sensors: [
                TempReading(key: "Tp01P", temp: 40.1),
                TempReading(key: "Tp05P", temp: 71.3),
            ]
        )
        let hottest = try curve([(50, 1500), (70, 3500)], sensor: "hottest")
        #expect(hottest.sensorValue(in: temps) == 71.3)

        let avg = try curve([(50, 1500), (70, 3500)], sensor: "avg")
        #expect(avg.sensorValue(in: temps) == 52.5)

        let key = try curve([(50, 1500), (70, 3500)], sensor: "Tp01P")
        #expect(key.sensorValue(in: temps) == 40.1)

        let missing = try curve([(50, 1500), (70, 3500)], sensor: "TpZZZ")
        #expect(missing.sensorValue(in: temps) == nil)
    }

    // MARK: codable + summary

    @Test func codableRoundtrip() throws {
        let c = try curve([(50, 1500), (70, 3500)], sensor: "avg")
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(FanCurve.self, from: data)
        #expect(decoded == c)
    }

    @Test func summary() throws {
        let c = try curve([(50, 1500), (70, 3500), (80, 6000)])
        #expect(c.summary == "50:1500 70:3500 80:6000")
    }

    // MARK: persistence

    @Test func curveStoreRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fand-curve-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CurveStore(path: dir.appendingPathComponent("curve.json").path)
        let c1 = try curve([(50, 1500), (70, 3500)], sensor: "hottest")
        let c2 = try curve([(40, 1200), (60, 3000)], sensor: "avg")

        // Nothing on disk yet.
        #expect(store.load().isEmpty)

        #expect(store.save([0: c1, 1: c2]))
        let loaded = store.load()
        #expect(loaded.count == 2)
        #expect(loaded[0] == c1)
        #expect(loaded[1] == c2)

        // Saving an empty dict removes the file.
        #expect(store.save([:]))
        #expect(store.load().isEmpty)
    }

    @Test func desiredCurveEquatable() throws {
        let c = try curve([(50, 1500), (70, 3500)])
        #expect(Desired.curve(c) == Desired.curve(c))
        #expect(Desired.curve(c) != Desired.manual(2000))
    }

    // MARK: default curve

    @Test func defaultCurveIsValid() {
        let c = FanCurve.defaultCurve
        #expect(c.points.count >= 2)
        #expect(c.sensor == "hottest")
        let temps = c.points.map(\.temp)
        #expect(temps == temps.sorted())
        #expect(zip(temps, temps.dropFirst()).allSatisfy { $0 < $1 })
        #expect(c.points.allSatisfy { $0.rpm >= 0 })
    }

    @Test func defaultCurveFollowsBalancedPreset() {
        let c = FanCurve.defaultCurve
        // Silent floor below 50 °C.
        #expect(c.target(forTemp: 40) == 1500)
        #expect(c.target(forTemp: 50) == 1500)
        // 45% at 75 °C ≈ 1950.
        #expect(c.target(forTemp: 75) == 1950)
        // 60% at 85 °C ≈ 2600 (the community's "50–70% above 85 °C" band).
        #expect(c.target(forTemp: 85) == 2600)
        // 80% at 95 °C ≈ 3450.
        #expect(c.target(forTemp: 95) == 3450)
        // Full speed at 100 °C ≈ firmware max (4296/4744 on M1 Pro 14").
        #expect(c.target(forTemp: 100) == 4300)
        #expect(c.target(forTemp: 110) == 4300)
    }

    @Test func defaultCurveStaysWithinAbsoluteCeiling() {
        for p in FanCurve.defaultCurve.points {
            #expect(p.rpm <= HardwareCaps.absoluteCeiling)
        }
    }
}
