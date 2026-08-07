import Foundation
import FandCore
import Darwin

@main
struct FandCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            usage()
            exit(1)
        }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "status":
            StatusCommand.run()
        case "set":
            SetCommand.run(rest)
        case "auto":
            AutoCommand.run()
        case "install":
            InstallCommand.run(rest)
        case "uninstall":
            UninstallCommand.run()
        case "daemon":
            FandDaemon.run()
        case "help", "--help", "-h":
            usage()
            exit(0)
        case "version", "--version", "-v":
            print("fandctl \(FandDaemon.version)")
            exit(0)
        default:
            stderr("fandctl: unknown command '\(cmd)'")
            usage()
            exit(1)
        }
    }

    static func usage() {
        print("""
        fandctl \(FandDaemon.version) — control the fand daemon (macOS fan control)

        usage:
          fandctl status                    show fans, temperatures, daemon state
          fandctl set <rpm|auto> [fan]      pin fan speed(s) to <rpm> RPM, or back to automatic
          fandctl auto                      all fans back to automatic control
          fandctl daemon                    run the fand daemon in the foreground (root)
          fandctl install [--binary <p>]    install the launchd service (root)
          fandctl uninstall                 remove the launchd service (root)
          fandctl help                      show this help
          fandctl version                   show version

        examples:
          fandctl set 2500                  pin every fan to 2500 RPM
          fandctl set 1500 0                pin only fan 0 to 1500 RPM
          fandctl set auto                  all fans back to automatic
        """)
    }

    static func stderr(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}

// MARK: - status

enum StatusCommand {
    static func run() {
        do {
            let resp = try IPCClient.request(Request(v: 1, cmd: "status"), timeout: IPCServer.statusTimeout)
            guard resp.ok, let fans = resp.fans, let temps = resp.temps else {
                print("error: \(resp.error ?? "unknown error")")
                exit(1)
            }
            print("fand daemon: running")
            renderFans(fans)
            renderTemps(temps)
        } catch FandError.daemonNotRunning {
            print("fand daemon: not running (showing direct SMC snapshot — read-only)")
            directStatus()
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    /// Fallback when the daemon is down: reads need no privileges, so the CLI
    /// opens its own SMC connection.
    static func directStatus() {
        do {
            let smc = try SMC()
            var fans = try FanDiscovery.discover(smc)
            for i in fans.indices {
                FanDiscovery.refresh(smc, &fans[i])
            }
            let tempKeys = Temps.discover(smc)
            let temps = Temps.refresh(smc, keys: tempKeys)
            let statuses = fans.map { f in
                FanStatus(
                    index: f.index,
                    name: f.name,
                    min: f.min,
                    max: f.max,
                    actual: f.actual,
                    target: f.target,
                    mode: f.mode.rawValue,
                    pinned: false
                )
            }
            renderFans(statuses)
            renderTemps(TempsStatus(
                avg: temps.avg,
                hottestKey: temps.hottest?.key,
                hottestValue: temps.hottest?.temp,
                sensors: temps.sensors.map { TempsStatus.SensorReading(key: $0.key, temp: $0.temp) }
            ))
        } catch {
            print("error: could not read the SMC: \(error)")
            exit(1)
        }
    }

    static func renderFans(_ fans: [FanStatus]) {
        print("fans: \(fans.count)")
        for f in fans {
            let mode = pad(f.mode, to: 7)
            let actual = pad("\(Int(f.actual))", to: 6)
            let target = pad("\(Int(f.target))", to: 6)
            print("  [\(f.index)] \(pad(f.name, to: 12)) mode=\(mode) actual=\(actual) target=\(target) limit=\(Int(f.max)) pinned=\(f.pinned ? "yes" : "no")")
        }
    }

    static func renderTemps(_ t: TempsStatus) {
        guard !t.sensors.isEmpty else {
            print("temps: none")
            return
        }
        let hottest: String
        if let k = t.hottestKey, let v = t.hottestValue {
            hottest = String(format: "%.1f°C (%@)", v, k)
        } else {
            hottest = "n/a"
        }
        print(String(format: "temps: avg %.1f°C  hottest %@", t.avg, hottest))
        let line = t.sensors.map { String(format: "%@ %.1f°C", $0.key, $0.temp) }.joined(separator: "  ")
        print("  \(line)")
    }

    static func pad(_ s: String, to n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}

// MARK: - set

enum SetCommand {
    static func run(_ args: [String]) {
        guard let target = args.first else {
            FandCtl.stderr("usage: fandctl set <rpm|auto> [fan-index]")
            exit(1)
        }
        var fan: Int?
        if args.count >= 2 {
            guard let i = Int(args[1]) else {
                FandCtl.stderr("error: invalid fan index '\(args[1])'")
                exit(1)
            }
            fan = i
        }

        let req: Request
        if target == "auto" {
            req = Request(v: 1, cmd: fan == nil ? "all_auto" : "set_auto", fan: fan)
        } else {
            guard let rpm = Double(target), rpm >= 0 else {
                FandCtl.stderr("error: invalid rpm '\(target)'")
                exit(1)
            }
            if rpm > Double(HardwareCaps.absoluteCeiling) {
                FandCtl.stderr("error: \(Int(rpm)) RPM exceeds the absolute ceiling of \(Int(HardwareCaps.absoluteCeiling)) RPM — no MacBook fan spins that fast (per-model limits apply; see fandctl status)")
                exit(1)
            }
            req = Request(v: 1, cmd: "set", fan: fan, rpm: rpm)
        }

        do {
            let resp = try IPCClient.request(req, timeout: IPCServer.setTimeout)
            guard resp.ok else {
                FandCtl.stderr("error: \(resp.error ?? "unknown error")")
                exit(1)
            }
            print(resp.message ?? "ok")
            if let fans = resp.fans {
                StatusCommand.renderFans(fans)
            }
        } catch FandError.daemonNotRunning {
            FandCtl.stderr("error: fand daemon is not running — start it with: sudo fandctl daemon   (or install: sudo ./install.sh)")
            exit(1)
        } catch {
            FandCtl.stderr("error: \(error)")
            exit(1)
        }
    }
}

// MARK: - auto

enum AutoCommand {
    static func run() {
        do {
            let resp = try IPCClient.request(Request(v: 1, cmd: "all_auto"), timeout: IPCServer.setTimeout)
            guard resp.ok else {
                FandCtl.stderr("error: \(resp.error ?? "unknown error")")
                exit(1)
            }
            print(resp.message ?? "ok")
            if let fans = resp.fans {
                StatusCommand.renderFans(fans)
            }
        } catch FandError.daemonNotRunning {
            FandCtl.stderr("error: fand daemon is not running — start it with: sudo fandctl daemon   (or install: sudo ./install.sh)")
            exit(1)
        } catch {
            FandCtl.stderr("error: \(error)")
            exit(1)
        }
    }
}

// MARK: - install / uninstall

enum InstallCommand {
    static let plistPath = "/Library/LaunchDaemons/com.fand.daemon.plist"
    static let binaryDestination = "/usr/local/bin/fand"

    static let plistTemplate = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.fand.daemon</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/local/bin/fand</string>
            <string>daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/var/log/fand.log</string>
        <key>StandardErrorPath</key>
        <string>/var/log/fand.log</string>
    </dict>
    </plist>
    """

    static func run(_ args: [String]) {
        guard getuid() == 0 else {
            FandCtl.stderr("error: install must run as root — try: sudo fandctl install   (or: sudo ./install.sh)")
            exit(1)
        }

        var binaryOverride: String?
        var rest = args
        while !rest.isEmpty {
            if rest[0] == "--binary", rest.count >= 2 {
                binaryOverride = rest[1]
                rest.removeFirst(2)
            } else {
                FandCtl.stderr("error: unknown install option '\(rest[0])'")
                exit(1)
            }
        }

        let candidates = [binaryOverride, "/usr/local/bin/fand", ".build/release/fand"].compactMap { $0 }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            FandCtl.stderr("error: fand binary not found — run ./install.sh first (it builds and installs both binaries)")
            exit(1)
        }

        let fm = FileManager.default
        // The resolved source may already be the destination (e.g. install.sh
        // installed the binary moments ago) — deleting it before copying would
        // delete the very file we need to copy.
        if binary != binaryDestination {
            do {
                if fm.fileExists(atPath: binaryDestination) {
                    try fm.removeItem(atPath: binaryDestination)
                }
                try fm.copyItem(atPath: binary, toPath: binaryDestination)
            } catch {
                FandCtl.stderr("error: could not install binary: \(error)")
                exit(1)
            }
        }

        do {
            try Data(plistTemplate.utf8).write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } catch {
            FandCtl.stderr("error: could not write \(plistPath): \(error)")
            exit(1)
        }

        let r = runProcess("/bin/launchctl", ["bootstrap", "system", plistPath])
        if r.status != 0 {
            let k = runProcess("/bin/launchctl", ["kickstart", "system/com.fand.daemon"])
            if k.status != 0 {
                FandCtl.stderr("warning: launchctl bootstrap failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        print("installed:")
        print("  daemon binary: \(binaryDestination)")
        print("  launchd plist: \(plistPath)")
        print("  logs:          /var/log/fand.log")
        print("the fand daemon is now running (and will start at boot);")
        print("stopping it restores all fans to automatic control.")
    }
}

enum UninstallCommand {
    static func run() {
        guard getuid() == 0 else {
            FandCtl.stderr("error: uninstall must run as root — try: sudo fandctl uninstall")
            exit(1)
        }
        // bootout stops the daemon (SIGTERM → graceful restore-to-auto).
        let r = runProcess("/bin/launchctl", ["bootout", "system/com.fand.daemon"])
        if r.status != 0 {
            let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty {
                FandCtl.stderr("note: launchctl: \(msg)")
            }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: InstallCommand.plistPath) {
            do {
                try fm.removeItem(atPath: InstallCommand.plistPath)
            } catch {
                FandCtl.stderr("warning: could not remove \(InstallCommand.plistPath): \(error)")
            }
        }
        print("uninstalled — the daemon restored fans to automatic control before exiting")
    }
}

// MARK: - process helper

@discardableResult
func runProcess(_ launchPath: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        return (-1, "", "\(error)")
    }
    p.waitUntilExit()
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out, err)
}
