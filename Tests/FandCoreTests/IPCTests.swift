import Testing
import Foundation
@testable import FandCore

@Suite struct IPCTests {

    @Test func requestRoundtrip() throws {
        let requests: [Request] = [
            Request(v: 1, cmd: "status"),
            Request(v: 1, cmd: "set", rpm: 2000),
            Request(v: 1, cmd: "set", fan: 1, rpm: 4000),
            Request(v: 1, cmd: "set_auto", fan: 0),
            Request(v: 1, cmd: "set_auto"),
            Request(v: 1, cmd: "all_auto"),
            Request(v: 1, cmd: "curve", points: [CurvePoint(temp: 50, rpm: 1500), CurvePoint(temp: 70, rpm: 3500)], sensor: "hottest"),
            Request(v: 1, cmd: "curve", fan: 1, points: [CurvePoint(temp: 40, rpm: 1200), CurvePoint(temp: 60, rpm: 3000)], sensor: "Tp05P"),
            Request(v: 1, cmd: "curve_off"),
            Request(v: 1, cmd: "curve_off", fan: 0),
            Request(v: 1, cmd: "quit"),
        ]
        for req in requests {
            let data = try JSONEncoder().encode(req)
            let decoded = try JSONDecoder().decode(Request.self, from: data)
            #expect(decoded == req)
        }
    }

    @Test func responseRoundtrip() throws {
        let resp = Response(
            ok: true,
            fans: [
                FanStatus(index: 0, name: "Left fan", min: 0, max: 6000,
                          actual: 2010, target: 2000, mode: "manual", pinned: true),
                FanStatus(index: 1, name: "Right fan", min: 0, max: 6000,
                          actual: 1240, target: 0, mode: "auto", pinned: false),
            ],
            temps: TempsStatus(
                avg: 46.8,
                hottestKey: "Tp05P",
                hottestValue: 59.2,
                sensors: [TempsStatus.SensorReading(key: "Tp05P", temp: 59.2)]
            ),
            curves: [
                CurveStatus(fan: 0, sensor: "hottest", points: [CurvePoint(temp: 50, rpm: 1500), CurvePoint(temp: 70, rpm: 3500)]),
            ],
            message: "set manual: fan 0: 2000 RPM"
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        #expect(decoded == resp)
        #expect(decoded.curves?.count == 1)
        #expect(decoded.curves?.first?.points.count == 2)
    }

    @Test func errorResponseOmitsNilFields() throws {
        let resp = Response(ok: false, error: "rejected by thermal manager (SMC 0x82)")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        #expect(decoded == resp)
        #expect(decoded.fans == nil)
        #expect(decoded.temps == nil)
        #expect(decoded.message == nil)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(Request.self, from: Data("not json".utf8)) }
        // Missing required field "cmd".
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(Request.self, from: Data(#"{"v":1}"#.utf8)) }
        // Wrong types.
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(Request.self, from: Data(#"{"v":"one","cmd":"status"}"#.utf8)) }
    }

    @Test func requestEnvelope() throws {
        let data = try JSONEncoder().encode(Request(v: 1, cmd: "set", fan: 0, rpm: 1500))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"cmd\":\"set\""))
        #expect(json.contains("\"fan\":0"))
        #expect(json.contains("\"rpm\":1500"))
        #expect(json.contains("\"v\":1"))
    }

    @Test func fanStatusAndTempsEquatable() {
        let a = FanStatus(index: 0, name: "Fan 0", min: 0, max: 6000, actual: 1, target: 2, mode: "auto", pinned: false)
        #expect(a == a)
        #expect(a != FanStatus(index: 0, name: "Fan 0", min: 0, max: 6000, actual: 1, target: 2, mode: "auto", pinned: true))

        let t = TempsStatus(avg: 40, hottestKey: nil, hottestValue: nil, sensors: [])
        #expect(t == TempsStatus(avg: 40, hottestKey: nil, hottestValue: nil, sensors: []))
    }
}
