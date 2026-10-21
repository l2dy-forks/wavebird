import Foundation
import Testing
@testable import WaveBird

struct DSUOutputTests {
    private func device(_ number: Int) -> DeviceID {
        DeviceID(transport: .ble, raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!)
    }

    private func dataPacket(for output: DSUOutput, device: DeviceID, sequence: UInt32 = 1) -> [UInt8]? {
        guard let key = output.key(for: device), let snapshot = output.snapshot(for: key) else { return nil }
        return [UInt8](DSUProtocol.dataResponse(
            slot: snapshot.index,
            info: snapshot.portInfo,
            state: snapshot.state,
            sequence: sequence,
            timestampMicros: 1,
            serverID: 1
        ))
    }

    private func float32(_ bytes: [UInt8], at offset: Int) -> Float {
        let bits = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Float(bitPattern: bits)
    }

    @Test func logicalKeysHaveStableDistinctLocalMACAddresses() {
        let solo = DSUPadKey.solo("LEFT")
        let pair = DSUPadKey.joyConPair("LEFT", "RIGHT")
        #expect(solo.macAddress == DSUPadKey.solo("LEFT").macAddress)
        #expect(solo.macAddress != pair.macAddress)
        #expect(solo.macAddress.count == 6)
        #expect(solo.macAddress[0] & 0x03 == 0x02)
    }

    @Test func pairSplitAndRepairAllocateLogicalPadsAndReleaseSlots() {
        let output = DSUOutput(backend: .dsu)
        let left = device(1)
        let right = device(2)
        let pair = DSUPadKey.joyConPair("L", "R")

        #expect(output.attach(pair, devices: [left, right]))
        #expect(output.padCount == 1)
        #expect(output.key(for: left) == pair)
        #expect(output.key(for: right) == pair)
        let pairSlot = output.snapshot(for: pair)?.index
        output.release(pair)
        #expect(output.padCount == 0)
        #expect(output.key(for: left) == nil)

        let leftSolo = DSUPadKey.solo("L")
        let rightSolo = DSUPadKey.solo("R")
        #expect(output.attach(leftSolo, devices: [left]))
        #expect(output.attach(rightSolo, devices: [right]))
        #expect(output.padCount == 2)
        #expect(output.snapshot(for: leftSolo)?.index != output.snapshot(for: rightSolo)?.index)
        #expect(leftSolo.macAddress != rightSolo.macAddress)
        output.release(leftSolo)
        #expect(output.padCount == 1)
        #expect(output.key(for: right) == rightSolo)

        output.release(rightSolo)
        #expect(output.attach(pair, devices: [left, right]))
        #expect(output.padCount == 1)
        #expect(output.snapshot(for: pair)?.index == pairSlot)
        #expect(output.key(for: left) == pair)
        #expect(output.key(for: right) == pair)
    }

    @Test func splitJoyConPacketsContainOnlyTheirSideState() {
        let output = DSUOutput(backend: .dsu)
        let leftID = device(3)
        let rightID = device(4)
        let leftKey = DSUPadKey.solo("LEFT")
        let rightKey = DSUPadKey.solo("RIGHT")
        #expect(output.attach(leftKey, devices: [leftID]))
        #expect(output.attach(rightKey, devices: [rightID]))

        var leftState = ControllerState.zero
        leftState.leftStick = SIMD2(512, -256)
        leftState.buttons = [.minus, .capture, .sl, .sr]
        leftState.shoulders = StandardShoulders(
            leftBumper: true,
            leftTriggerDigital: true,
            leftTriggerAnalog: 255
        )
        var rightState = ControllerState.zero
        rightState.rightStick = SIMD2(-768, 1024)
        rightState.buttons = [.a, .home, .sl, .sr]
        rightState.shoulders = StandardShoulders(
            rightBumper: true,
            rightTriggerDigital: true,
            rightTriggerAnalog: 200
        )
        output.publish(leftState, for: leftID)
        output.publish(rightState, for: rightID)

        let left = dataPacket(for: output, device: leftID)!
        let right = dataPacket(for: output, device: rightID)!
        #expect(left[36] == 0x01)
        #expect(left[37] == 0x05)
        #expect(left[39] == 1)
        #expect(left[40] > 128 && left[42] == 128)
        #expect(left[41] > 128)
        #expect(right[36] == 0)
        #expect(right[37] == 0x2A) // right trigger + right bumper + A
        #expect(right[38] == 1)
        #expect(right[40] == 128 && right[42] < 128)
        #expect(right[43] < 128)
    }

    @Test func mergedJoyConPacketCombinesBothHalvesAndPrefersLeftMotion() {
        let output = DSUOutput(backend: .dsu)
        let leftID = device(30)
        let rightID = device(31)
        let pair = DSUPadKey.joyConPair("LEFT", "RIGHT")
        #expect(output.attach(pair, devices: [leftID, rightID]))

        var left = ControllerState.zero
        left.leftStick = SIMD2(1024, 512)
        left.buttons = [.minus, .zl]
        left.shoulders = StandardShoulders(leftTriggerDigital: true, leftTriggerAnalog: 255)
        left.imu = IMUSample(accelX: 1, accelY: 2, accelZ: 3, gyroX: 4, gyroY: 5, gyroZ: 6)
        var right = ControllerState.zero
        right.rightStick = SIMD2(-1024, -512)
        right.buttons = [.a, .plus]
        right.shoulders = StandardShoulders(rightBumper: true)
        right.imu = IMUSample(accelX: 10, accelY: 20, accelZ: 30, gyroX: 40, gyroY: 50, gyroZ: 60)

        let merged = JoyConPairProfile.merge(left: left, right: right)
        output.publish(merged, for: leftID)
        let packet = dataPacket(for: output, device: rightID)!
        #expect(output.padCount == 1)
        #expect(packet[36] == 0x09) // minus + options
        #expect(packet[37] == 0x29) // left trigger + right bumper + A
        #expect(packet[40] > 128 && packet[42] < 128)
        #expect(float32(packet, at: 76) == Float(1) / 4096)
        #expect(float32(packet, at: 80) == Float(2) / 4096)
        #expect(float32(packet, at: 84) == Float(3) / 4096)
    }

    @Test func disconnectingEitherPairMemberReleasesSharedPadAndSlotsAreBounded() {
        let output = DSUOutput(backend: .dsu)
        let left = device(5)
        let right = device(6)
        let pair = DSUPadKey.joyConPair("L", "R")
        #expect(output.attach(pair, devices: [left, right]))
        output.release(device: right)
        #expect(output.padCount == 0)
        #expect(output.key(for: left) == nil)

        let ids = (10...13).map(device)
        for index in 0..<4 {
            #expect(output.attach(.solo("pad-\(index)"), devices: [ids[index]]))
        }
        #expect(output.padCount == 4)
        #expect(!output.attach(.solo("fifth"), devices: [device(14)]))
    }

    @Test func motionTimestampChangesWhenAnyIMUComponentChanges() {
        let output = DSUOutput(backend: .dsu)
        let id = device(20)
        let key = DSUPadKey.solo("motion")
        #expect(output.attach(key, devices: [id]))
        var state = ControllerState.zero
        state.imu = IMUSample(accelX: 0, accelY: 0, accelZ: 4096, gyroX: 0, gyroY: 0, gyroZ: 0)
        output.publish(state, for: id)
        let first = output.snapshot(for: key)!.motionTimestampMicros

        state.imu?.gyroX = 100
        output.publish(state, for: id)
        let afterGyro = output.snapshot(for: key)!.motionTimestampMicros
        #expect(afterGyro > first)

        output.publish(state, for: id)
        #expect(output.snapshot(for: key)!.motionTimestampMicros == afterGyro)

        state.imu?.accelX = 100
        output.publish(state, for: id)
        #expect(output.snapshot(for: key)!.motionTimestampMicros > afterGyro)
    }
}
