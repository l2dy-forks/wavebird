import Foundation
import Testing
@testable import WaveBird

struct DSUProtocolTests {
    private func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func float32(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: uint32(bytes, at: offset))
    }

    private func checksumIsValid(_ data: Data) -> Bool {
        var bytes = [UInt8](data)
        let stored = uint32(bytes, at: 8)
        bytes.replaceSubrange(8..<12, with: repeatElement(0, count: 4))
        return DSUProtocol.crc32(bytes) == stored
    }

    @Test func crc32MatchesIEEEVector() {
        #expect(DSUProtocol.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func versionResponseHasCemuhookHeaderAndCRC() {
        let bytes = [UInt8](DSUProtocol.versionResponse(serverID: 0x1234_5678))
        #expect(bytes.count == 22)
        #expect(Array(bytes[0..<4]) == Array("DSUS".utf8))
        #expect(uint16(bytes, at: 4) == 1001)
        #expect(uint16(bytes, at: 6) == 6)
        #expect(uint32(bytes, at: 12) == 0x1234_5678)
        #expect(uint32(bytes, at: 16) == DSUProtocol.messageVersion)
        #expect(uint16(bytes, at: 20) == 1001)
        #expect(checksumIsValid(Data(bytes)))
    }

    @Test func portInfoResponseDescribesAnEmptyOrConnectedSlot() {
        let empty = [UInt8](DSUProtocol.portInfoResponse(slot: 3, info: nil, serverID: 9))
        #expect(empty.count == 32)
        #expect(uint16(empty, at: 6) == 16)
        #expect(uint32(empty, at: 16) == DSUProtocol.messagePorts)
        #expect(Array(empty[20..<32]) == [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(checksumIsValid(Data(empty)))

        let info = DSUPortInfo(macAddress: Data([2, 1, 2, 3, 4, 5]))
        let connected = [UInt8](DSUProtocol.portInfoResponse(slot: 1, info: info, serverID: 9))
        #expect(Array(connected[20..<31]) == [1, 2, 2, 2, 2, 1, 2, 3, 4, 5, 0])
        #expect(connected[31] == 0)
    }

    @Test func dataPacketEncodesButtonsAxesTriggersMotionAndExactLength() {
        var state = ControllerState.zero
        state.leftStick = SIMD2(2047, -2047)
        state.rightStick = SIMD2(0, 1024)
        state.buttons = [.minus, .dpadUp, .a, .y, .home, .capture]
        state.shoulders = StandardShoulders(
            leftBumper: true,
            rightBumper: false,
            leftTriggerDigital: false,
            rightTriggerDigital: true,
            leftTriggerAnalog: 0x10,
            rightTriggerAnalog: 0x80
        )
        state.imu = IMUSample(accelX: 4096, accelY: -2048, accelZ: 0, gyroX: 100, gyroY: -100, gyroZ: 0)

        let info = DSUPortInfo(macAddress: Data([2, 10, 20, 30, 40, 50]))
        let packet = DSUProtocol.dataResponse(
            slot: 2,
            info: info,
            state: state,
            sequence: 0x7856_3412,
            timestampMicros: 0x0102_0304_0506_0708,
            serverID: 0xAABB_CCDD
        )
        let bytes = [UInt8](packet)

        #expect(bytes.count == DSUProtocol.packetSize)
        #expect(uint16(bytes, at: 6) == 84)
        #expect(uint32(bytes, at: 12) == 0xAABB_CCDD)
        #expect(uint32(bytes, at: 16) == DSUProtocol.messageData)
        #expect(Array(bytes[20..<31]) == [2, 2, 2, 2, 2, 10, 20, 30, 40, 50, 0])
        #expect(bytes[31] == 1)
        #expect(uint32(bytes, at: 32) == 0x7856_3412)
        #expect(bytes[36] == 0x11) // minus + up
        #expect(bytes[37] == 0xA6) // R2 + L1 + A + Y
        #expect(bytes[38] == 1 && bytes[39] == 1)
        #expect(Array(bytes[40..<44]) == [255, 255, 128, 64])
        #expect(Array(bytes[48..<56]) == [255, 0, 255, 0, 0, 255, 128, 16])
        #expect(Array(bytes[56..<68]) == Array(repeating: 0, count: 12))
        #expect(uint32(bytes, at: 68) == 0x0506_0708)
        #expect(float32(bytes, at: 76) == 1)
        #expect(float32(bytes, at: 80) == -0.5)
        let gyroScale = Float(936.0 / 0x343B)
        #expect(abs(float32(bytes, at: 88) - Float(-100) * gyroScale) < 0.0001) // pitch = gyroY
        #expect(float32(bytes, at: 92) == 0) // yaw = gyroZ
        #expect(abs(float32(bytes, at: 96) - Float(100) * gyroScale) < 0.0001) // roll = gyroX
        #expect(checksumIsValid(packet))
    }

    @Test func clientPacketValidationHonorsHeaderLength() {
        var request = [UInt8](repeating: 0, count: 20)
        request.replaceSubrange(0..<4, with: Array("DSUC".utf8))
        request[4] = UInt8(DSUProtocol.version & 0xFF)
        request[5] = UInt8(DSUProtocol.version >> 8)
        request[6] = 4
        request[16] = UInt8(DSUProtocol.messageVersion & 0xFF)
        request[17] = UInt8((DSUProtocol.messageVersion >> 8) & 0xFF)
        request[18] = UInt8((DSUProtocol.messageVersion >> 16) & 0xFF)
        request[19] = UInt8((DSUProtocol.messageVersion >> 24) & 0xFF)
        #expect(DSUProtocol.validClientPacket(Data(request))?.message == DSUProtocol.messageVersion)
        #expect(DSUProtocol.validClientPacket(Data(request.dropLast())) == nil)
    }
}
