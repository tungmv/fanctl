import Foundation
import Darwin

// MARK: - Protocol types (JSON-lines over a Unix domain socket)

public struct Request: Codable, Equatable {
    public var v: Int
    public var cmd: String
    public var fan: Int?
    public var rpm: Double?
    public var points: [CurvePoint]?
    public var sensor: String?

    public init(v: Int, cmd: String, fan: Int? = nil, rpm: Double? = nil,
                points: [CurvePoint]? = nil, sensor: String? = nil) {
        self.v = v
        self.cmd = cmd
        self.fan = fan
        self.rpm = rpm
        self.points = points
        self.sensor = sensor
    }
}

public struct FanStatus: Codable, Equatable {
    public let index: Int
    public let name: String
    public let min: Float
    public let max: Float
    public let actual: Float
    public let target: Float
    public let mode: String
    public let pinned: Bool

    public init(index: Int, name: String, min: Float, max: Float, actual: Float,
                target: Float, mode: String, pinned: Bool) {
        self.index = index
        self.name = name
        self.min = min
        self.max = max
        self.actual = actual
        self.target = target
        self.mode = mode
        self.pinned = pinned
    }
}

public struct TempsStatus: Codable, Equatable {
    public struct SensorReading: Codable, Equatable {
        public let key: String
        public let temp: Float

        public init(key: String, temp: Float) {
            self.key = key
            self.temp = temp
        }
    }

    public let avg: Float
    public let hottestKey: String?
    public let hottestValue: Float?
    public let sensors: [SensorReading]

    public init(avg: Float, hottestKey: String?, hottestValue: Float?, sensors: [SensorReading]) {
        self.avg = avg
        self.hottestKey = hottestKey
        self.hottestValue = hottestValue
        self.sensors = sensors
    }
}

/// An active curve as reported in status responses.
public struct CurveStatus: Codable, Equatable {
    public let fan: Int
    public let sensor: String
    public let points: [CurvePoint]

    public init(fan: Int, sensor: String, points: [CurvePoint]) {
        self.fan = fan
        self.sensor = sensor
        self.points = points
    }
}

public struct Response: Codable, Equatable {
    public var v: Int
    public var ok: Bool
    public var fans: [FanStatus]?
    public var temps: TempsStatus?
    public var curves: [CurveStatus]?
    public var message: String?
    public var error: String?

    public init(v: Int = 1, ok: Bool, fans: [FanStatus]? = nil, temps: TempsStatus? = nil,
                curves: [CurveStatus]? = nil, message: String? = nil, error: String? = nil) {
        self.v = v
        self.ok = ok
        self.fans = fans
        self.temps = temps
        self.curves = curves
        self.message = message
        self.error = error
    }
}

// MARK: - Socket helpers

func ipcFillSunPath(_ addr: inout sockaddr_un, path: String) {
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
        pathPtr.withMemoryRebound(to: UInt8.self, capacity: 104) { raw in
            let n = min(bytes.count, 103)
            for i in 0..<n {
                raw[i] = bytes[i]
            }
            raw[n] = 0
        }
    }
}

/// Reads a single newline-terminated line, bounded by a receive timeout.
/// Returns nil on timeout / EOF / error.
func ipcReadLine(fd: Int32, timeout: TimeInterval) -> String? {
    var tv = timeval(
        tv_sec: Int(timeout),
        tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
    )
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var buf = [UInt8](repeating: 0, count: 4096)
    var line = ""
    while line.utf8.count < 65_536 {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 {
            break
        }
        if let nl = buf[..<n].firstIndex(of: 0x0A) {
            line += String(decoding: buf[..<nl], as: UTF8.self)
            return line
        }
        line += String(decoding: buf[..<n], as: UTF8.self)
    }
    return line.isEmpty ? nil : line
}

func ipcSendAll(fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        guard let base = ptr.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let n = send(fd, base.advanced(by: sent), data.count - sent, 0)
            if n <= 0 {
                break
            }
            sent += n
        }
    }
}

// MARK: - Client

public enum IPCClient {
    /// Sends one request to the daemon and waits for the response.
    public static func request(_ req: Request, timeout: TimeInterval,
                               socketPath: String = IPCServer.socketPath) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw FandError.socket("socket(): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        ipcFillSunPath(&addr, path: socketPath)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            if e == ECONNREFUSED || e == ENOENT {
                throw FandError.daemonNotRunning
            }
            throw FandError.socket("connect: \(String(cString: strerror(e)))")
        }

        var payload = Data()
        if let body = try? JSONEncoder().encode(req) {
            payload = body
        }
        payload.append(0x0A)
        ipcSendAll(fd: fd, payload)

        guard let line = ipcReadLine(fd: fd, timeout: timeout) else {
            throw FandError.timeout
        }
        do {
            return try JSONDecoder().decode(Response.self, from: Data(line.utf8))
        } catch {
            throw FandError.socket("bad response from daemon: \(error)")
        }
    }
}

// MARK: - Server

/// Unix-domain-socket server. One request per connection:
/// connect → send one JSON line → read one JSON line → close.
public final class IPCServer: @unchecked Sendable {
    public static let socketPath = "/tmp/fand.sock"
    public static let statusTimeout: TimeInterval = 5
    public static let setTimeout: TimeInterval = 15
    public static let quitTimeout: TimeInterval = 5

    private let controller: FanController
    private let queue = DispatchQueue(label: "fand.ipc.accept")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(controller: FanController) {
        self.controller = controller
    }

    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw FandError.socket("socket(): \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        ipcFillSunPath(&addr, path: Self.socketPath)
        var bindRC: Int32 = -1
        withUnsafePointer(to: &addr) { ptr in
            bindRC = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRC == 0 else {
            let e = errno
            close(fd)
            throw FandError.socket("bind \(Self.socketPath): \(String(cString: strerror(e)))")
        }
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw FandError.socket("listen: \(String(cString: strerror(e)))")
        }
        chmod(Self.socketPath, mode_t(0o666))

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            self?.acceptReady()
        }
        src.resume()
        source = src
    }

    private func acceptReady() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            handleConnection(client)
        }
    }

    private func handleConnection(_ fd: Int32) {
        let controller = self.controller
        DispatchQueue.global(qos: .userInitiated).async {
            defer { close(fd) }
            guard let line = ipcReadLine(fd: fd, timeout: 2.0), !line.isEmpty else {
                return
            }
            let response: Response
            do {
                let req = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                guard req.v == 1 else {
                    throw FandError.invalidInput("unsupported protocol version \(req.v)")
                }
                response = Self.handle(req, controller: controller)
            } catch let e as FandError {
                response = Response(ok: false, error: e.description)
            } catch {
                response = Response(ok: false, error: "malformed request: \(error)")
            }
            var payload = Data()
            if let body = try? JSONEncoder().encode(response) {
                payload = body
            }
            payload.append(0x0A)
            ipcSendAll(fd: fd, payload)
        }
    }

    private static func handle(_ req: Request, controller: FanController) -> Response {
        let outcome = CommandOutcome()
        let timeout: TimeInterval
        switch req.cmd {
        case "status":
            controller.enqueue(DaemonCommand(.status, outcome: outcome))
            timeout = statusTimeout
        case "set":
            guard let rpm = req.rpm, rpm >= 0, rpm.isFinite else {
                return Response(ok: false, error: "set requires a non-negative rpm")
            }
            controller.enqueue(DaemonCommand(.setTarget(fan: req.fan, rpm: Float(rpm)), outcome: outcome))
            timeout = setTimeout
        case "set_auto":
            controller.enqueue(DaemonCommand(.setAuto(fan: req.fan), outcome: outcome))
            timeout = setTimeout
        case "all_auto":
            controller.enqueue(DaemonCommand(.allAuto, outcome: outcome))
            timeout = setTimeout
        case "curve":
            guard let points = req.points else {
                return Response(ok: false, error: "curve requires points (temp:rpm pairs)")
            }
            let sensor = (req.sensor ?? "").isEmpty ? "hottest" : req.sensor!
            controller.enqueue(DaemonCommand(.setCurve(fan: req.fan, points: points, sensor: sensor), outcome: outcome))
            timeout = setTimeout
        case "curve_off":
            controller.enqueue(DaemonCommand(.curveOff(fan: req.fan), outcome: outcome))
            timeout = setTimeout
        case "quit":
            controller.enqueue(DaemonCommand(.quit(restore: true), outcome: outcome))
            timeout = quitTimeout
        default:
            return Response(ok: false, error: "unknown command '\(req.cmd)'")
        }

        guard let result = outcome.wait(timeout: timeout) else {
            return Response(ok: false, error: "daemon did not finish '\(req.cmd)' within \(Int(timeout))s")
        }
        let snapshot = controller.currentSnapshot()
        switch result {
        case .success(let message):
            return Response(ok: true, fans: snapshot.fans, temps: snapshot.temps,
                            curves: snapshot.curves, message: message)
        case .failure(let e):
            return Response(ok: false, fans: snapshot.fans, temps: snapshot.temps,
                            curves: snapshot.curves, error: e.description)
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
        let fd = listenFD
        listenFD = -1
        if fd >= 0 {
            close(fd)
        }
        unlink(Self.socketPath)
    }
}
