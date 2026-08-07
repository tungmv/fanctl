import Testing
@testable import FandCore

@Suite struct SMCTests {

    // MARK: fourcc

    @Test func fourcc() throws {
        #expect(try FandCore.fourcc("F0Ac") == 0x46304163)
        #expect(try FandCore.fourcc("#KEY") == 0x234B4559)
        #expect(try FandCore.fourcc("flt ") == 0x666C7420)
        #expect(try FandCore.fourcc("sp78") == 0x73703738)
    }

    @Test func fourccRoundtrip() throws {
        for s in ["F0Ac", "F0Tg", "#KEY", "flt ", "fpe2", "sp78", "FS! ", "ch8*"] {
            #expect(fourccString(try FandCore.fourcc(s)) == s)
        }
    }

    @Test func fourccInvalid() {
        #expect(throws: FandError.self) { _ = try FandCore.fourcc("AB") }
        #expect(throws: FandError.self) { _ = try FandCore.fourcc("ABCDE") }
        #expect(throws: FandError.self) { _ = try FandCore.fourcc("") }
    }

    // MARK: SMCKeyData layout

    @Test func keyDataSize() {
        #expect(MemoryLayout<SMCKeyData>.size == 80)
        #expect(SMCKeyData.byteCount == 80)
    }

    @Test func keyDataFieldOffsets() {
        var kd = SMCKeyData()
        // Header integer fields are host-endian UInt32s (the SMC reads the
        // packed fourcc value natively). On this LE host the byte image is the
        // reverse of the big-endian-packed value.
        kd.key = 0x01020304
        #expect(kd.loadBytes(0..<4) == [4, 3, 2, 1])
        #expect(kd.key == 0x01020304)

        kd.keyInfoSize = 0x11223344
        #expect(kd.loadBytes(28..<32) == [0x44, 0x33, 0x22, 0x11])
        #expect(kd.keyInfoSize == 0x11223344)

        kd.keyInfoType = 0xAABBCCDD
        #expect(kd.loadBytes(32..<36) == [0xDD, 0xCC, 0xBB, 0xAA])
        #expect(kd.keyInfoType == 0xAABBCCDD)

        kd.keyInfoAttrs = 0x7F
        #expect(kd.loadBytes(36..<37) == [0x7F])

        kd.result = 0x84
        #expect(kd.loadBytes(40..<41) == [0x84])

        kd.status = 0x01
        #expect(kd.loadBytes(41..<42) == [0x01])

        kd.data8 = 0x09
        #expect(kd.loadBytes(42..<43) == [0x09])

        kd.data32 = 0x00000007
        #expect(kd.loadBytes(44..<48) == [7, 0, 0, 0])
        #expect(kd.data32 == 7)
    }

    @Test func keyDataDataBytes() {
        var kd = SMCKeyData()
        let bytes = (0..<32).map { UInt8($0) }
        kd.dataBytes = bytes
        #expect(kd.dataBytes == bytes)
        #expect(kd.dataBytes.count == 32)
        // dataBytes lives at offset 48: the header bytes must be untouched.
        #expect(kd.loadBytes(44..<48) == [0, 0, 0, 0])
        // Short writes leave the tail zero (fresh struct).
        var short = SMCKeyData()
        short.dataBytes = [1, 2, 3, 4, 5]
        #expect(Array(short.dataBytes.prefix(5)) == [1, 2, 3, 4, 5])
        #expect(short.dataBytes.dropFirst(5).allSatisfy { $0 == 0 })
    }

    // MARK: value decoding

    @Test func valueFloatLittleEndian() {
        let raw = Float(1250).bitPattern.littleEndian
        let bytes = withUnsafeBytes(of: raw) { Array($0) }
        let v = SMCValue(dataType: try! FandCore.fourcc("flt "), size: 4, bytes: bytes)
        #expect(v.asFloat32(bigEndian: false) == 1250)
    }

    @Test func valueFloatBigEndian() {
        let raw = Float(1250).bitPattern.bigEndian
        let bytes = withUnsafeBytes(of: raw) { Array($0) }
        let v = SMCValue(dataType: try! FandCore.fourcc("flt "), size: 4, bytes: bytes)
        #expect(v.asFloat32(bigEndian: true) == 1250)
    }

    @Test func valueFPE2() {
        let v = SMCValue(dataType: try! FandCore.fourcc("fpe2"), size: 2, bytes: [0x13, 0x88])
        #expect(v.asFPE2() == 1250)
    }

    @Test func valueSP78() {
        let v = SMCValue(dataType: try! FandCore.fourcc("sp78"), size: 2, bytes: [0x32, 0x80])
        #expect(v.asSP78() == 50.5)
        let negative = SMCValue(dataType: try! FandCore.fourcc("sp78"), size: 2, bytes: [0xFF, 0x00])
        #expect(negative.asSP78() == -1)
    }

    @Test func valueUI8() {
        let v = SMCValue(dataType: try! FandCore.fourcc("ui8 "), size: 1, bytes: [7])
        #expect(v.asUInt8() == 7)
    }

    @Test func valueAsFloatDispatch() {
        #expect(SMCValue(dataType: try! FandCore.fourcc("sp78"), size: 2, bytes: [0x32, 0x80]).asFloat() == 50.5)
        #expect(SMCValue(dataType: try! FandCore.fourcc("fpe2"), size: 2, bytes: [0x13, 0x88]).asFloat() == 1250)
        #expect(SMCValue(dataType: try! FandCore.fourcc("ui8 "), size: 1, bytes: [1]).asFloat() == nil)
        #expect(SMCValue(dataType: try! FandCore.fourcc("flt "), size: 2, bytes: [0, 0]).asFloat32() == nil)
    }

    // MARK: key count

    @Test func parseKeyCountBigEndian() {
        let v = SMCValue(dataType: try! FandCore.fourcc("ui32"), size: 4, bytes: [0, 0, 0, 5])
        #expect(SMC.parseKeyCount(from: v) == 5)
    }

    @Test func parseKeyCountLittleEndianFallback() {
        let v = SMCValue(dataType: try! FandCore.fourcc("ui32"), size: 4, bytes: [5, 0, 0, 0])
        #expect(SMC.parseKeyCount(from: v) == 5)
    }

    @Test func parseKeyCountRejectsGarbage() {
        #expect(SMC.parseKeyCount(from: SMCValue(dataType: try! FandCore.fourcc("ui32"), size: 4, bytes: [0, 0, 0, 0])) == nil)
        #expect(SMC.parseKeyCount(from: SMCValue(dataType: try! FandCore.fourcc("ui32"), size: 4, bytes: [0xFF, 0xFF, 0xFF, 0xFF])) == nil)
        #expect(SMC.parseKeyCount(from: SMCValue(dataType: try! FandCore.fourcc("ui32"), size: 4, bytes: [0xFF, 0xFF, 0xFF, 0x05])) == nil)
    }
}
