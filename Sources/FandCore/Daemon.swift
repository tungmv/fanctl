import Foundation
import Darwin

/// The fand daemon: wires up signal handling, the IPC server and the control
/// thread, then waits for a graceful quit (which restores all fans to
/// automatic control before exiting).
public enum FandDaemon {
    public static let version = "0.3.0"

    nonisolated(unsafe) private static var server: IPCServer?
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    public static func run() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, first != "daemon" {
            stderr("fand: unknown argument '\(first)' — fand is the daemon binary; use 'fandctl' for control commands")
            exit(2)
        }

        if getuid() != 0 {
            stderr("warning: not running as root — reads work, but fan writes will be rejected by the SMC (start with sudo)")
        }

        let log: (String) -> Void = { msg in
            FileHandle.standardOutput.write(Data("[\(timestampString())] \(msg)\n".utf8))
        }
        log("fand \(version) daemon starting")

        // Refuse to double-run: if the socket already answers, another daemon
        // (or the launchd service) is alive.
        if (try? IPCClient.request(Request(v: 1, cmd: "status"), timeout: 1.0)) != nil {
            stderr("fand: another daemon instance is already running")
            exit(1)
        }

        let controller = FanController(logHandler: log)

        // SIGTERM (launchctl stop / reboot), SIGINT (Ctrl-C), SIGHUP all map to
        // a graceful quit that restores automatic control.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "fand.signal.\(sig)"))
            src.setEventHandler {
                controller.requestQuit(restore: true)
            }
            src.resume()
            signalSources.append(src)
        }

        do {
            let srv = IPCServer(controller: controller)
            try srv.start()
            server = srv
        } catch {
            stderr("fand: could not start IPC server: \(error)")
            exit(1)
        }
        log("listening on \(IPCServer.socketPath)")

        Thread.detachNewThread {
            controller.run()
        }

        while !controller.isDone {
            Thread.sleep(forTimeInterval: 0.05)
        }
        server?.stop()
        log("fand daemon exited")
        exit(Int32(controller.processExitCode))
    }

    private static func stderr(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
