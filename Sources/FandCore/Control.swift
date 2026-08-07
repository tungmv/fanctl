import Foundation

/// Per-fan desired state. Memory-only by design: a daemon restart returns
/// every fan to automatic control.
public enum Desired: Equatable {
    case untouched
    case auto
    case manual(Float)
}

/// A point-in-time view of the daemon's world, served to IPC clients.
public struct DaemonSnapshot {
    public let fans: [FanStatus]
    public let temps: TempsStatus
    public let ftstHeld: Bool

    public init(fans: [FanStatus], temps: TempsStatus, ftstHeld: Bool) {
        self.fans = fans
        self.temps = temps
        self.ftstHeld = ftstHeld
    }
}

/// Pure decision logic, extracted so it is unit-testable without hardware.
public enum ControlLogic {
    /// `Ftst` (the M3/M4 thermal-manager unlock flag) is released only when we
    /// set it and no fan is manual — neither by our desire nor on the hardware.
    public static func shouldReleaseFtst(held: Bool, anyDesiredManual: Bool, anyHardwareManual: Bool) -> Bool {
        held && !anyDesiredManual && !anyHardwareManual
    }

    /// Resolves an optional fan index to the list of fans a command applies to.
    public static func resolveIndices(fan: Int?, count: Int) -> Result<[Int], FandError> {
        if let fan {
            guard fan >= 0, fan < count else {
                return .failure(.invalidInput("no fan with index \(fan) — this Mac has \(count)"))
            }
            return .success([fan])
        }
        return .success(Array(0..<count))
    }
}

/// One-shot result carrier for a command processed by the control thread.
/// The IPC server waits on it (bounded by a timeout); the control thread
/// finishes it the moment the hardware work is done or abandoned.
public final class CommandOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private let sem = DispatchSemaphore(value: 0)
    private var result: Result<String, FandError>?

    public init() {}

    public func finish(_ result: Result<String, FandError>) {
        lock.lock()
        self.result = result
        lock.unlock()
        sem.signal()
    }

    /// Returns the result, or nil if the timeout expired first.
    public func wait(timeout: TimeInterval) -> Result<String, FandError>? {
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

/// A command queued for the control thread.
public struct DaemonCommand {
    public enum Kind: Equatable {
        case status
        case setTarget(fan: Int?, rpm: Float)
        case setAuto(fan: Int?)
        case allAuto
        case quit(restore: Bool)
    }

    public let kind: Kind
    public let outcome: CommandOutcome?

    public init(_ kind: Kind, outcome: CommandOutcome? = nil) {
        self.kind = kind
        self.outcome = outcome
    }
}

/// The daemon's brain. Owns the single SMC connection used for writes and
/// runs entirely on one dedicated control thread; the IPC server enqueues
/// commands and waits for their outcomes.
///
/// All shared state is guarded by locks, which is why this class is
/// `@unchecked Sendable` (the SMC connection itself is confined to the control
/// thread and never touched elsewhere).
public final class FanController: @unchecked Sendable {
    // Timing constants, ported from the reference implementation.
    public static let reassertInterval: TimeInterval = 2.0
    public static let modeRetries = 300
    public static let modeRetryDelay: TimeInterval = 0.1
    public static let ftstRetries = 100
    public static let ftstRetryDelay: TimeInterval = 0.05
    public static let ftstSettle: TimeInterval = 3.0
    public static let tgRetries = 10
    public static let writeRetryDelay: TimeInterval = 0.05

    private let lock = NSLock()
    private var pending: [DaemonCommand] = []
    private let wake = DispatchSemaphore(value: 0)
    private var quitRequested = false
    private var done = false
    private var exitCode = 0

    private let snapshotLock = NSLock()
    private var snapshot = DaemonSnapshot(
        fans: [],
        temps: TempsStatus(avg: 0, hottestKey: nil, hottestValue: nil, sensors: []),
        ftstHeld: false
    )

    private let logHandler: (String) -> Void

    public init(logHandler: @escaping (String) -> Void) {
        self.logHandler = logHandler
    }

    // MARK: - Thread-safe entry points (IPC server / signal handlers)

    public var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    public var processExitCode: Int {
        lock.lock()
        defer { lock.unlock() }
        return exitCode
    }

    public func currentSnapshot() -> DaemonSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    public func enqueue(_ cmd: DaemonCommand) {
        lock.lock()
        pending.append(cmd)
        lock.unlock()
        wake.signal()
    }

    public func requestQuit(restore: Bool) {
        enqueue(DaemonCommand(.quit(restore: restore)))
    }

    // MARK: - Control thread

    public func run() {
        // Everything below runs on the control thread; the SMC connection is
        // created here and never leaves this thread.
        let smc: SMC
        do {
            smc = try SMC()
        } catch {
            logHandler("fatal: \(error)")
            finish(exitCode: 1)
            return
        }

        var fans: [Fan]
        do {
            fans = try FanDiscovery.discover(smc)
        } catch {
            logHandler("fatal: fan discovery failed: \(error)")
            finish(exitCode: 1)
            return
        }
        guard !fans.isEmpty else {
            logHandler("no fans found — nothing to control")
            finish(exitCode: 0)
            return
        }
        logHandler("connected to AppleSMC: \(fans.count) fan(s)")
        for fan in fans {
            logHandler("\(fan.name): speed limit \(Int(fan.max)) RPM (\(fan.maxSource))")
        }

        let tempKeys = Temps.discover(smc)
        logHandler("\(tempKeys.count) temperature sensor(s)")

        var desired: [Desired] = Array(repeating: .untouched, count: fans.count)
        var ftstHeld = false
        var restoring = false
        var lastReassertError: [Int: String] = [:]

        // ------- helpers (control thread only) -------

        func interrupted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return quitRequested
        }

        /// Sleeps in small chunks so a quit lands within ~50 ms.
        func waitInterruptible(_ duration: TimeInterval) {
            let step = 0.05
            var remaining = duration
            while remaining > 0 && !interrupted() {
                Thread.sleep(forTimeInterval: min(step, remaining))
                remaining -= step
            }
        }

        func writeRetry(_ key: String, _ data: [UInt8], attempts: Int) -> Result<Void, FandError> {
            for attempt in 0..<attempts {
                if interrupted() {
                    return .failure(.interrupted)
                }
                do {
                    try smc.write(key, data)
                    return .success(())
                } catch let e as FandError {
                    if attempt == attempts - 1 {
                        return .failure(e)
                    }
                } catch {
                    return .failure(.internalError("\(error)"))
                }
                waitInterruptible(Self.writeRetryDelay)
            }
            return .failure(.interrupted)
        }

        func fanToAuto(_ fan: Fan) {
            do {
                try FanDiscovery.writeMode(smc, fan: fan, manual: false)
            } catch {
                logHandler("warning: could not set \(fan.name) to automatic: \(error)")
            }
            let key = FanDiscovery.keyName(fan.index, "Tg")
            if let info = try? smc.keyInfo(fourcc(key)),
               let data = try? FanDiscovery.encodeRPM(dataType: info.dataType, rpm: 0) {
                _ = writeRetry(key, data, attempts: Self.tgRetries)
            }
        }

        /// Puts a fan in manual mode, running the M3/M4 thermal-manager unlock
        /// sequence when the firmware rejects the direct mode write:
        /// 1. try `F{i}Md = 1` directly (works on M1, and on M3 when the
        ///    system is not actively asserting mode 3);
        /// 2. on rejection: `Ftst = 1`, wait ~3 s for the thermal manager to
        ///    yield, then retry the mode write (300 × 100 ms);
        /// 3. caller then writes the target RPM to `F{i}Tg`.
        func engageManual(_ i: Int) -> Result<Void, FandError> {
            let fan = fans[i]
            if FanDiscovery.readMode(smc, fan: fan) == .manual {
                return .success(())
            }
            guard smc.exists(fan.mdKey) else {
                return .failure(.message("manual-mode key \(fan.mdKey) is not present on this Mac"))
            }
            do {
                try FanDiscovery.writeMode(smc, fan: fan, manual: true)
                return .success(())
            } catch let e as FandError {
                if case .notPrivileged = e {
                    return .failure(.notPrivileged)
                }
                guard smc.exists("Ftst") else {
                    return .failure(.message("enable manual mode: \(e)"))
                }
                logHandler("unlocking fan control from thermal manager (takes 3–6s)…")
                if case .failure(let ue) = writeRetry("Ftst", [1], attempts: Self.ftstRetries) {
                    return .failure(.message("unlock (Ftst): \(ue)"))
                }
                ftstHeld = true
                waitInterruptible(Self.ftstSettle)
                if interrupted() {
                    return .failure(.interrupted)
                }
                for attempt in 0..<Self.modeRetries {
                    if interrupted() {
                        return .failure(.interrupted)
                    }
                    do {
                        try FanDiscovery.writeMode(smc, fan: fan, manual: true)
                        return .success(())
                    } catch let e2 as FandError {
                        if attempt == Self.modeRetries - 1 {
                            return .failure(.message("enable manual mode after unlock: \(e2)"))
                        }
                    } catch {
                        return .failure(.internalError("\(error)"))
                    }
                    waitInterruptible(Self.modeRetryDelay)
                }
                return .failure(.interrupted)
            } catch {
                return .failure(.internalError("\(error)"))
            }
        }

        func writeTargetWithRetry(_ i: Int, rpm: Float) -> Result<Void, FandError> {
            let key = FanDiscovery.keyName(fans[i].index, "Tg")
            guard let info = try? smc.keyInfo(fourcc(key)),
                  let data = try? FanDiscovery.encodeRPM(dataType: info.dataType, rpm: rpm) else {
                return .failure(.badData)
            }
            return writeRetry(key, data, attempts: Self.tgRetries)
        }

        /// `Ftst` is released conservatively: only when we set it AND no fan
        /// is manual (neither desired nor on hardware). Leaving it stuck at 1
        /// would partially inhibit macOS thermal management.
        func maybeReleaseFtst() {
            guard ftstHeld else { return }
            let anyDesiredManual = desired.contains { if case .manual = $0 { true } else { false } }
            let anyHardwareManual = fans.contains { FanDiscovery.readMode(smc, fan: $0) == .manual }
            if ControlLogic.shouldReleaseFtst(
                held: true,
                anyDesiredManual: anyDesiredManual,
                anyHardwareManual: anyHardwareManual
            ) {
                do {
                    try smc.write("Ftst", [0])
                } catch {
                    logHandler("warning: could not release Ftst: \(error)")
                }
                ftstHeld = false
            }
        }

        func restoreAll() {
            restoring = true
            for i in fans.indices where desired[i] != .untouched {
                logHandler("restoring \(fans[i].name) to automatic…")
                fanToAuto(fans[i])
                desired[i] = .untouched
            }
            if ftstHeld {
                logHandler("releasing thermal-manager unlock (Ftst)…")
                do {
                    try smc.write("Ftst", [0])
                } catch {
                    logHandler("warning: could not release Ftst: \(error)")
                }
                ftstHeld = false
            }
            restoring = false
        }

        /// Runs whenever the loop has been idle for `reassertInterval`
        /// seconds. Sleep/wake resets `Ftst` in firmware and the system
        /// reclaims the fans, so this re-engages our desired state whenever
        /// hardware mode and desired mode diverge.
        func reassert() {
            guard !restoring else { return }
            for i in fans.indices {
                let mode = FanDiscovery.readMode(smc, fan: fans[i])
                switch desired[i] {
                case .untouched:
                    continue
                case .manual(let rpm):
                    guard mode != .manual else { continue }
                    logHandler("system reclaimed \(fans[i].name) — re-engaging manual control…")
                    let outcome: Result<Void, FandError>
                    switch engageManual(i) {
                    case .success:
                        outcome = writeTargetWithRetry(i, rpm: rpm)
                    case .failure(let e):
                        outcome = .failure(e)
                    }
                    if case .failure(let e) = outcome {
                        let msg = "\(e)"
                        if lastReassertError[i] != msg {
                            logHandler("re-engage \(fans[i].name) failed: \(msg)")
                            lastReassertError[i] = msg
                        }
                    } else {
                        lastReassertError[i] = nil
                    }
                case .auto:
                    if mode != .auto {
                        fanToAuto(fans[i])
                    }
                }
            }
            maybeReleaseFtst()
        }

        func applySetTarget(fan: Int?, rpm: Float) -> Result<String, FandError> {
            let indices: [Int]
            switch ControlLogic.resolveIndices(fan: fan, count: fans.count) {
            case .success(let v):
                indices = v
            case .failure(let e):
                return .failure(e)
            }
            var notes: [String] = []
            var applied: [(index: Int, rpm: Float)] = []
            for i in indices {
                let clamped = FanDiscovery.clampedTarget(rpm, min: fans[i].min, max: fans[i].max)
                if clamped != rpm {
                    notes.append("\(fans[i].name): clamped \(Int(rpm)) → \(Int(clamped)) (\(fans[i].maxSource))")
                }
                applied.append((i, clamped))
                desired[i] = .manual(clamped)
            }
            for (i, _) in applied {
                if case .failure(let e) = engageManual(i) {
                    return .failure(.message("\(fans[i].name): \(e)"))
                }
            }
            for (i, rpm) in applied {
                if case .failure(let e) = writeTargetWithRetry(i, rpm: rpm) {
                    return .failure(.message("\(fans[i].name): target write failed: \(e)"))
                }
            }
            maybeReleaseFtst()
            let summary = applied.map { "fan \($0.index): \(Int($0.rpm)) RPM" }.joined(separator: ", ")
            let note = notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")"
            return .success("set manual: \(summary)\(note)")
        }

        func applySetAuto(fan: Int?) -> Result<String, FandError> {
            let indices: [Int]
            switch ControlLogic.resolveIndices(fan: fan, count: fans.count) {
            case .success(let v):
                indices = v
            case .failure(let e):
                return .failure(e)
            }
            for i in indices {
                desired[i] = .auto
                if FanDiscovery.readMode(smc, fan: fans[i]) != .auto {
                    fanToAuto(fans[i])
                }
            }
            maybeReleaseFtst()
            let summary = indices.map { "fan \($0)" }.joined(separator: ", ")
            return .success("automatic: fan \(summary)")
        }

        func applyAllAuto() -> Result<String, FandError> {
            applySetAuto(fan: nil)
        }

        func publishSnapshot() {
            for i in fans.indices {
                FanDiscovery.refresh(smc, &fans[i])
            }
            let temps = Temps.refresh(smc, keys: tempKeys)
            let statuses = fans.indices.map { i in
                FanStatus(
                    index: fans[i].index,
                    name: fans[i].name,
                    min: fans[i].min,
                    max: fans[i].max,
                    actual: fans[i].actual,
                    target: fans[i].target,
                    mode: fans[i].mode.rawValue,
                    pinned: desired[i] != .untouched
                )
            }
            let ts = TempsStatus(
                avg: temps.avg,
                hottestKey: temps.hottest?.key,
                hottestValue: temps.hottest?.temp,
                sensors: temps.sensors.map { TempsStatus.SensorReading(key: $0.key, temp: $0.temp) }
            )
            let snap = DaemonSnapshot(fans: statuses, temps: ts, ftstHeld: ftstHeld)
            snapshotLock.lock()
            snapshot = snap
            snapshotLock.unlock()
        }

        // ------- main loop -------

        publishSnapshot()
        logHandler("ready")

        loop: while true {
            let timedOut = wake.wait(timeout: .now() + Self.reassertInterval) == .timedOut
            if timedOut {
                if !restoring {
                    reassert()
                }
                publishSnapshot()
                continue
            }

            lock.lock()
            let cmd = pending.isEmpty ? nil : pending.removeFirst()
            lock.unlock()
            guard let cmd else { continue }

            var result: Result<String, FandError> = .success("ok")
            switch cmd.kind {
            case .status:
                publishSnapshot()
            case .setTarget(let fan, let rpm):
                result = applySetTarget(fan: fan, rpm: rpm)
            case .setAuto(let fan):
                result = applySetAuto(fan: fan)
            case .allAuto:
                result = applyAllAuto()
            case .quit(let restore):
                if restore {
                    restoreAll()
                    result = .success("fans restored to automatic; fand daemon exiting")
                } else {
                    result = .success("quitting; keeping current fan settings")
                }
                publishSnapshot()
                cmd.outcome?.finish(result)
                break loop
            }
            cmd.outcome?.finish(result)
            publishSnapshot()
        }

        // Drain any commands that arrived while we were quitting.
        lock.lock()
        let remaining = pending
        pending.removeAll()
        lock.unlock()
        for c in remaining {
            c.outcome?.finish(.failure(.message("fand daemon is exiting")))
        }

        logHandler("daemon exiting")
        finish(exitCode: 0)
    }

    private func finish(exitCode: Int) {
        lock.lock()
        done = true
        self.exitCode = exitCode
        lock.unlock()
    }
}
