import Foundation

enum DSUMotionConvention: Sendable, Equatable {
    case waveBird
    case joyCon2Android
}

enum DSUProtocol {
    static let version: UInt16 = 1001
    static let messageVersion: UInt32 = 0x0010_0000
    static let messagePorts: UInt32 = 0x0010_0001
    static let messageData: UInt32 = 0x0010_0002
    static let packetSize = 100

    static func versionResponse(serverID: UInt32) -> Data {
        packet(message: messageVersion, payload: [UInt8(version & 0xFF), UInt8(version >> 8)], serverID: serverID)
    }

    static func portInfoResponse(slot: UInt8, info: DSUPortInfo?, serverID: UInt32) -> Data {
        var payload = portInfoPayload(slot: slot, info: info)
        payload.append(0)
        return packet(message: messagePorts, payload: payload, serverID: serverID)
    }

    static func dataResponse(
        slot: UInt8,
        info: DSUPortInfo,
        state: ControllerState,
        sequence: UInt32,
        timestampMicros: UInt64,
        serverID: UInt32,
        motionConvention: DSUMotionConvention = .waveBird
    ) -> Data {
        var payload = portInfoPayload(slot: slot, info: info)
        payload.append(1) // connected
        appendLE(sequence, to: &payload)

        let shoulders = state.shoulders
        var firstButtons: UInt8 = 0
        if state.buttons.contains(.minus) { firstButtons |= 0x01 }
        if state.buttons.contains(.stickL) { firstButtons |= 0x02 }
        if state.buttons.contains(.stickR) { firstButtons |= 0x04 }
        if state.buttons.contains(.plus) || state.buttons.contains(.start) { firstButtons |= 0x08 }
        if state.buttons.contains(.dpadUp) { firstButtons |= 0x10 }
        if state.buttons.contains(.dpadRight) { firstButtons |= 0x20 }
        if state.buttons.contains(.dpadDown) { firstButtons |= 0x40 }
        if state.buttons.contains(.dpadLeft) { firstButtons |= 0x80 }

        var secondButtons: UInt8 = 0
        if shoulders.leftTriggerDigital { secondButtons |= 0x01 }
        if shoulders.rightTriggerDigital { secondButtons |= 0x02 }
        if shoulders.leftBumper { secondButtons |= 0x04 }
        if shoulders.rightBumper { secondButtons |= 0x08 }
        if state.buttons.contains(.x) { secondButtons |= 0x10 }
        if state.buttons.contains(.a) { secondButtons |= 0x20 }
        if state.buttons.contains(.b) { secondButtons |= 0x40 }
        if state.buttons.contains(.y) { secondButtons |= 0x80 }
        payload.append(firstButtons)
        payload.append(secondButtons)

        payload.append(state.buttons.contains(.home) ? 1 : 0)
        payload.append(state.buttons.contains(.capture) ? 1 : 0)
        payload.append(axisByte(state.leftStick.x))
        // Workaround: invert DSU Y for observed client behavior; root cause is unknown.
        payload.append(axisByte(-Int(state.leftStick.y)))
        payload.append(axisByte(state.rightStick.x))
        payload.append(axisByte(-Int(state.rightStick.y)))

        payload.append(state.buttons.contains(.dpadLeft) ? 0xFF : 0)
        payload.append(state.buttons.contains(.dpadDown) ? 0xFF : 0)
        payload.append(state.buttons.contains(.dpadRight) ? 0xFF : 0)
        payload.append(state.buttons.contains(.dpadUp) ? 0xFF : 0)
        payload.append(state.buttons.contains(.y) ? 0xFF : 0)
        payload.append(state.buttons.contains(.b) ? 0xFF : 0)
        payload.append(state.buttons.contains(.a) ? 0xFF : 0)
        payload.append(state.buttons.contains(.x) ? 0xFF : 0)
        payload.append(shoulders.rightBumper ? 0xFF : 0)
        payload.append(shoulders.leftBumper ? 0xFF : 0)
        payload.append(shoulders.rightTriggerAnalog)
        payload.append(shoulders.leftTriggerAnalog)

        payload.append(contentsOf: repeatElement(0, count: 12)) // inactive touch placeholders
        appendLE(timestampMicros, to: &payload)
        if let imu = state.imu {
            switch motionConvention {
            case .waveBird:
                appendFloat(Float(imu.accelX) / 4096, to: &payload)
                appendFloat(Float(imu.accelY) / 4096, to: &payload)
                appendFloat(Float(imu.accelZ) / 4096, to: &payload)
                // Keep the previous Pro/GameCube DSU interpretation unless
                // their motion frames are validated against joycon2android.
                let gyroScale = Float(936.0 / 0x343B)
                appendFloat(Float(imu.gyroY) * gyroScale, to: &payload)
                appendFloat(Float(imu.gyroZ) * gyroScale, to: &payload)
                appendFloat(Float(imu.gyroX) * gyroScale, to: &payload)
            case .joyCon2Android:
                // NS2Report0x05 stores accel=(rawAy, -rawAx, rawAz) and
                // gyro=(rawGy, -rawGx, rawGz). Re-express those canonical axes
                // as joycon2android's raw Report 0x05 -> DSU frame.
                let accelScale: Float = 0.000244140625
                let gyroScale: Float = 0.06103515625
                appendFloat(Float(imu.accelY) * accelScale, to: &payload)
                appendFloat(-Float(imu.accelZ) * accelScale, to: &payload)
                appendFloat(Float(imu.accelX) * accelScale, to: &payload)
                // DSU gyro order is pitch, yaw, roll.
                appendFloat(-Float(imu.gyroY) * gyroScale, to: &payload)
                appendFloat(-Float(imu.gyroZ) * gyroScale, to: &payload)
                appendFloat(Float(imu.gyroX) * gyroScale, to: &payload)
            }
        } else {
            payload.append(contentsOf: repeatElement(0, count: 24))
        }

        return packet(message: messageData, payload: payload, serverID: serverID)
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func validClientPacket(_ data: Data) -> (message: UInt32, payload: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20,
              Array(bytes[0..<4]) == Array("DSUC".utf8),
              readLE(UInt16.self, from: bytes, at: 4) == version,
              let length = readLE(UInt16.self, from: bytes, at: 6)
        else { return nil }
        let packetEnd = 16 + Int(length)
        guard packetEnd >= 20, bytes.count >= packetEnd,
              let message = readLE(UInt32.self, from: bytes, at: 16)
        else { return nil }
        return (message, Data(bytes[20..<packetEnd]))
    }

    private static func packet(message: UInt32, payload: [UInt8], serverID: UInt32) -> Data {
        var bytes = Array("DSUS".utf8)
        appendLE(version, to: &bytes)
        appendLE(UInt16(4 + payload.count), to: &bytes)
        appendLE(UInt32(0), to: &bytes)
        appendLE(serverID, to: &bytes)
        appendLE(message, to: &bytes)
        bytes.append(contentsOf: payload)
        let checksum = crc32(bytes)
        writeLE(checksum, to: &bytes, at: 8)
        return Data(bytes)
    }

    private static func portInfoPayload(slot: UInt8, info: DSUPortInfo?) -> [UInt8] {
        guard let info else {
            return [slot, 0, 0, 0] + Array(repeating: 0, count: 6) + [0]
        }
        let mac = Array(info.macAddress.prefix(6)) + Array(repeating: 0, count: max(0, 6 - info.macAddress.count))
        return [slot, 2, 2, 2] + mac + [0]
    }

    private static func axisByte(_ value: Int16) -> UInt8 {
        axisByte(Int(value))
    }

    private static func axisByte(_ value: Int) -> UInt8 {
        let clamped = max(-2047, min(2047, value))
        let normalized = (Double(clamped) / 2047 + 1) * 127.5
        return UInt8(max(0, min(255, Int(normalized.rounded()))))
    }

    private static func appendFloat(_ value: Float, to bytes: inout [UInt8]) {
        appendLE(value.bitPattern, to: &bytes)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }

    private static func readLE<T: FixedWidthInteger>(_ type: T.Type, from bytes: [UInt8], at offset: Int) -> T? {
        guard offset >= 0, offset + MemoryLayout<T>.size <= bytes.count else { return nil }
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(bytes[offset + index]) << (index * 8)
        }
        return value
    }

    private static func writeLE<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8], at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { raw in
            bytes.replaceSubrange(offset..<(offset + raw.count), with: raw)
        }
    }
}

struct DSUPortInfo: Sendable {
    let macAddress: Data
}
