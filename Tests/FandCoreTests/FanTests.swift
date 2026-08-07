import Testing
@testable import FandCore

@Suite struct FanTests {

    @Test func keyNames() {
        #expect(FanDiscovery.keyName(0, "Ac") == "F0Ac")
        #expect(FanDiscovery.keyName(1, "Tg") == "F1Tg")
        #expect(FanDiscovery.keyName(12, "Mn") == "F12Mn")
    }

    // MARK: RPM encoding

    @Test func encodeRPMFloatLittleEndian() throws {
        let type = try FandCore.fourcc("flt ")
        let data = try FanDiscovery.encodeRPM(dataType: type, rpm: 2000)
        #expect(data.count == 4)
        let raw = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Float(bitPattern: UInt32(littleEndian: raw)) == 2000)
    }

    @Test func encodeRPMFPE2() throws {
        let type = try FandCore.fourcc("fpe2")
        #expect(try FanDiscovery.encodeRPM(dataType: type, rpm: 1250) == [0x13, 0x88])
        #expect(try FanDiscovery.encodeRPM(dataType: type, rpm: 0) == [0, 0])
        #expect(try FanDiscovery.encodeRPM(dataType: type, rpm: -100) == [0, 0])
        // clamps to 16383 → 0xFFFC
        #expect(try FanDiscovery.encodeRPM(dataType: type, rpm: 20_000) == [0xFF, 0xFC])
        #expect(try FanDiscovery.encodeRPM(dataType: type, rpm: 16_383) == [0xFF, 0xFC])
    }

    @Test func encodeRPMBadType() {
        #expect(throws: FandError.self) { _ = try FanDiscovery.encodeRPM(dataType: try! FandCore.fourcc("ui8 "), rpm: 1) }
    }

    // MARK: clamping

    @Test func clampTarget() {
        #expect(FanDiscovery.clampedTarget(2000, min: 0, max: 6000) == 2000)
        #expect(FanDiscovery.clampedTarget(999_999, min: 0, max: 6000) == 6000)
        #expect(FanDiscovery.clampedTarget(-5, min: 0, max: 6000) == 0)
        #expect(FanDiscovery.clampedTarget(3000, min: 1000, max: 5000) == 3000)
        #expect(FanDiscovery.clampedTarget(100, min: 1000, max: 5000) == 1000)
    }

    // MARK: modes

    @Test func modeFromRaw() {
        #expect(FanMode.fromRaw(0) == .auto)
        #expect(FanMode.fromRaw(1) == .manual)
        #expect(FanMode.fromRaw(3) == .system)
        #expect(FanMode.fromRaw(2) == .system)
        #expect(FanMode.fromRaw(255) == .system)
    }

    @Test func modeRawValues() {
        #expect(FanMode.auto.rawValue == "auto")
        #expect(FanMode.manual.rawValue == "manual")
        #expect(FanMode.system.rawValue == "system")
    }
}
