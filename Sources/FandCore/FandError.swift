import Foundation
import Darwin

/// Errors surfaced by fand, mirroring the reference implementation's `SmcError`
/// plus IPC/CLI-specific cases.
public enum FandError: Error, CustomStringConvertible {
    /// `IOServiceGetMatchingService("AppleSMC")` found nothing.
    case serviceNotFound
    /// `IOServiceOpen` failed with the given kernel return.
    case openFailed(kern_return_t)
    /// `IOConnectCallStructMethod` failed with the given kernel return.
    case callFailed(kern_return_t)
    /// SMC replied with result 0x84 (key not found).
    case keyNotFound
    /// SMC replies with kern 0xE00002C1 — writes require root.
    case notPrivileged
    /// SMC replied with a non-zero result byte (e.g. 0x82 = thermal manager rejection).
    case smcResult(UInt8)
    /// Value could not be decoded / key did not match expectations.
    case badData
    /// Operation aborted because a quit was requested mid-retry.
    case interrupted
    /// A pre-formatted user-facing message.
    case message(String)
    /// Bad input from the CLI or IPC layer.
    case invalidInput(String)
    /// Socket / IPC failures.
    case socket(String)
    /// Could not connect to the daemon's Unix socket.
    case daemonNotRunning
    /// The daemon did not answer within the timeout.
    case timeout
    /// Unexpected internal failure.
    case internalError(String)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found"
        case .openFailed(let kr):
            return String(format: "failed to open AppleSMC (kern 0x%x)", kr)
        case .callFailed(let kr):
            return String(format: "SMC call failed (kern 0x%x)", kr)
        case .keyNotFound:
            return "SMC key not found"
        case .notPrivileged:
            return "permission denied — writing fan speeds requires root (run the daemon with sudo)"
        case .smcResult(let r):
            if r == 0x82 {
                return "rejected by thermal manager (SMC 0x82)"
            }
            return String(format: "SMC error result 0x%x", r)
        case .badData:
            return "unexpected SMC data"
        case .interrupted:
            return "interrupted"
        case .message(let m):
            return m
        case .invalidInput(let m):
            return m
        case .socket(let m):
            return m
        case .daemonNotRunning:
            return "fand daemon is not running"
        case .timeout:
            return "timed out waiting for fand daemon"
        case .internalError(let m):
            return "internal error: \(m)"
        }
    }
}
