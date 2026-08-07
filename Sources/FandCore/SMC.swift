import Foundation
import Darwin
import IOKit

// MARK: - fourcc

/// Packs a 4-character key into a big-endian UInt32 ("F0Ac" → 0x46304163).
public func fourcc(_ s: String) throws -> UInt32 {
    let b = Array(s.utf8)
    guard b.count == 4 else {
        throw FandError.invalidInput("SMC key must be exactly 4 ASCII characters: '\(s)'")
    }
    return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
}

/// Unpacks a UInt32 fourcc back into a 4-character string.
public func fourccString(_ v: UInt32) -> String {
    let b: [UInt8] = [
        UInt8((v >> 24) & 0xFF),
        UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF),
        UInt8(v & 0xFF),
    ]
    return String(decoding: b, as: UTF8.self)
}

// MARK: - SMCKeyData (the 80-byte wire struct)

/// The 80-byte SMC protocol struct, identical in layout to the struct used by
/// every SMC tool since smcFanControl. The layout is locked by
/// `MemoryLayout<SMCKeyData>.size == 80` and all fields are accessed through
/// explicit byte offsets (we deliberately do not rely on Swift struct layout):
///
/// ```
/// offset  size  field
/// 0       4     key          (fourcc, big-endian)
/// 4       8     vers         (SMC version; unused)
/// 12      16    p_limit      (power limits; unused)
/// 28      4     key_info.data_size
/// 32      4     key_info.data_type   (fourcc of the value type, e.g. "flt ")
/// 36      1     key_info.data_attributes
/// 40      1     result       (0 = ok, 0x84 = key not found, ...)
/// 41      1     status
/// 42      1     data8        (command byte / 1-byte value)
/// 44      4     data32       (u32 value, e.g. key index for CMD_READ_INDEX)
/// 48      32    bytes        (value payload)
/// ```
public struct SMCKeyData {
    public typealias ByteTuple80 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    public static let byteCount = 80

    private var storage: ByteTuple80 = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}

    // MARK: memory access

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try Swift.withUnsafeBytes(of: storage, body)
    }

    public mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try Swift.withUnsafeMutableBytes(of: &storage, body)
    }

    func loadUnaligned<T>(_ type: T.Type, at offset: Int) -> T {
        Swift.withUnsafeBytes(of: storage) { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
    }

    mutating func storeUnaligned<T>(_ value: T, at offset: Int) {
        Swift.withUnsafeMutableBytes(of: &storage) { $0.storeBytes(of: value, toByteOffset: offset, as: T.self) }
    }

    public func loadBytes(_ range: Range<Int>) -> [UInt8] {
        Swift.withUnsafeBytes(of: storage) { buf in Array(buf[range]) }
    }

    public mutating func storeBytes(_ bytes: [UInt8], at offset: Int) {
        Swift.withUnsafeMutableBytes(of: &storage) { buf in
            for (i, b) in bytes.enumerated() {
                buf[offset + i] = b
            }
        }
    }

    // MARK: explicit-offset accessors

    public var key: UInt32 {
        get { loadUnaligned(UInt32.self, at: 0) }
        set { storeUnaligned(newValue, at: 0) }
    }

    public var keyInfoSize: UInt32 {
        get { loadUnaligned(UInt32.self, at: 28) }
        set { storeUnaligned(newValue, at: 28) }
    }

    public var keyInfoType: UInt32 {
        get { loadUnaligned(UInt32.self, at: 32) }
        set { storeUnaligned(newValue, at: 32) }
    }

    public var keyInfoAttrs: UInt8 {
        get { loadUnaligned(UInt8.self, at: 36) }
        set { storeUnaligned(newValue, at: 36) }
    }

    public var result: UInt8 {
        get { loadUnaligned(UInt8.self, at: 40) }
        set { storeUnaligned(newValue, at: 40) }
    }

    public var status: UInt8 {
        get { loadUnaligned(UInt8.self, at: 41) }
        set { storeUnaligned(newValue, at: 41) }
    }

    public var data8: UInt8 {
        get { loadUnaligned(UInt8.self, at: 42) }
        set { storeUnaligned(newValue, at: 42) }
    }

    public var data32: UInt32 {
        get { loadUnaligned(UInt32.self, at: 44) }
        set { storeUnaligned(newValue, at: 44) }
    }

    /// The 32-byte value payload at offset 48.
    public var dataBytes: [UInt8] {
        get { loadBytes(48..<80) }
        set { storeBytes(Array(newValue.prefix(32)), at: 48) }
    }
}

// MARK: - SMCValue

/// A decoded key value: the runtime `data_type` plus the raw payload bytes.
public struct SMCValue {
    public let dataType: UInt32
    public let size: UInt32
    public let bytes: [UInt8]

    public init(dataType: UInt32, size: UInt32, bytes: [UInt8]) {
        self.dataType = dataType
        self.size = size
        self.bytes = bytes
    }

    public var typeString: String { fourccString(dataType) }

    /// Decode by runtime type ("flt ", "fpe2", "sp78").
    public func asFloat() -> Float? {
        switch typeString {
        case "flt ": return asFloat32()
        case "fpe2": return asFPE2()
        case "sp78": return asSP78()
        default: return nil
        }
    }

    /// IEEE-754 float. Little-endian on Apple Silicon, big-endian on Intel.
    public func asFloat32(bigEndian: Bool = !SMC.isAppleSilicon) -> Float? {
        guard size == 4, bytes.count >= 4 else { return nil }
        let raw: UInt32
        if bigEndian {
            raw = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        } else {
            raw = UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        }
        return Float(bitPattern: raw)
    }

    /// 14.2 fixed point, big-endian (used for RPM on Intel Macs).
    public func asFPE2() -> Float? {
        guard size == 2, bytes.count >= 2 else { return nil }
        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Float(raw) / 4
    }

    /// Signed 8.8 fixed point, big-endian (used for temperatures).
    public func asSP78() -> Float? {
        guard size == 2, bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        return Float(raw) / 256
    }

    public func asUInt8() -> UInt8? {
        bytes.first
    }

    /// Big-endian UInt32 (the wire order for integer SMC values). For sizes
    /// < 4 the value is zero-extended (e.g. `FNum` is a `ui8`).
    public func asUInt32() -> UInt32? {
        switch bytes.count {
        case 0:
            return nil
        case 1:
            return UInt32(bytes[0])
        case 2:
            return UInt32(bytes[0]) << 8 | UInt32(bytes[1])
        case 3:
            return UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
        default:
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        }
    }

    /// Little-endian UInt32 (fallback for `#KEY` on some firmware).
    public func asUInt32LE() -> UInt32? {
        switch bytes.count {
        case 0:
            return nil
        case 1:
            return UInt32(bytes[0])
        case 2:
            return UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        case 3:
            return UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        default:
            return UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0])
        }
    }
}

// MARK: - SMC

/// A userspace connection to the AppleSMC IOKit service.
///
/// IMPORTANT: an `SMC` instance is NOT thread-safe. The daemon creates one on
/// its control thread and never shares it; the CLI creates its own for
/// read-only fallback snapshots.
public final class SMC: @unchecked Sendable {
    public struct KeyInfo: Equatable {
        public let size: UInt32
        public let dataType: UInt32
        public init(size: UInt32, dataType: UInt32) {
            self.size = size
            self.dataType = dataType
        }
    }

    static let kernelIndexSMC: UInt32 = 2
    static let cmdReadBytes: UInt8 = 5
    static let cmdWriteBytes: UInt8 = 6
    static let cmdReadIndex: UInt8 = 8
    static let cmdReadKeyInfo: UInt8 = 9
    static let resultKeyNotFound: UInt8 = 0x84
    static let kIOReturnNotPrivileged: kern_return_t = Int32(bitPattern: 0xE00002C1)

    /// Runtime host detection: Apple Silicon vs Intel (affects float endianness
    /// and the manual-mode mechanism).
    public static let isAppleSilicon: Bool = {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]

    public init() throws {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw FandError.serviceNotFound
        }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr == KERN_SUCCESS else {
            throw FandError.openFailed(kr)
        }
        conn = c
    }

    deinit {
        if conn != 0 {
            IOServiceClose(conn)
        }
    }

    /// Sends one 80-byte struct-method call to the SMC.
    private func call(_ input: SMCKeyData) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outLen = SMCKeyData.byteCount
        let kr = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(
                    conn,
                    Self.kernelIndexSMC,
                    inPtr.baseAddress,
                    SMCKeyData.byteCount,
                    outPtr.baseAddress,
                    &outLen
                )
            }
        }
        if kr == Self.kIOReturnNotPrivileged {
            throw FandError.notPrivileged
        }
        if kr != KERN_SUCCESS {
            throw FandError.callFailed(kr)
        }
        switch output.result {
        case 0:
            return output
        case Self.resultKeyNotFound:
            throw FandError.keyNotFound
        default:
            throw FandError.smcResult(output.result)
        }
    }

    /// Returns (and caches) the data size + type of a key.
    public func keyInfo(_ key: UInt32) throws -> KeyInfo {
        if let cached = infoCache[key] {
            return cached
        }
        var input = SMCKeyData()
        input.key = key
        input.data8 = Self.cmdReadKeyInfo
        let out = try call(input)
        let info = KeyInfo(size: out.keyInfoSize, dataType: out.keyInfoType)
        infoCache[key] = info
        return info
    }

    /// Reads a key's value. Requires no privileges.
    public func read(_ key: String) throws -> SMCValue {
        let k = try fourcc(key)
        let info = try keyInfo(k)
        guard info.size <= 32 else {
            throw FandError.badData
        }
        var input = SMCKeyData()
        input.key = k
        input.keyInfoSize = info.size
        input.data8 = Self.cmdReadBytes
        let out = try call(input)
        return SMCValue(
            dataType: info.dataType,
            size: info.size,
            bytes: Array(out.dataBytes.prefix(Int(info.size)))
        )
    }

    /// Writes a key's raw value. Requires root (enforced by the SMC firmware).
    public func write(_ key: String, _ data: [UInt8]) throws {
        guard data.count <= 32 else {
            throw FandError.badData
        }
        let k = try fourcc(key)
        _ = try keyInfo(k)
        var input = SMCKeyData()
        input.key = k
        input.keyInfoSize = UInt32(data.count)
        input.data8 = Self.cmdWriteBytes
        input.dataBytes = data
        _ = try call(input)
    }

    /// Number of keys known to the SMC (`#KEY`), with BE/LE fallback.
    public func keyCount() throws -> UInt32 {
        guard let count = Self.parseKeyCount(from: try read("#KEY")) else {
            throw FandError.badData
        }
        return count
    }

    public static func parseKeyCount(from value: SMCValue) -> UInt32? {
        if let be = value.asUInt32(), be > 0, be < 100_000 {
            return be
        }
        if let le = value.asUInt32LE(), le > 0, le < 100_000 {
            return le
        }
        return nil
    }

    /// Returns the key at a given index (key enumeration).
    public func keyAt(_ index: UInt32) throws -> String {
        var input = SMCKeyData()
        input.data8 = Self.cmdReadIndex
        input.data32 = index
        let out = try call(input)
        return fourccString(out.key)
    }

    /// Whether a key exists (false on any error, including permission errors —
    /// existence checks are read-only and unprivileged).
    public func exists(_ key: String) -> Bool {
        guard let k = try? fourcc(key) else { return false }
        return (try? keyInfo(k)) != nil
    }
}
