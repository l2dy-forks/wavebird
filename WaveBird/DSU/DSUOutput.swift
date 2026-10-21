import CryptoKit
import Dispatch
import Foundation
import os

enum OutputBackend: String, Sendable, Equatable {
    case dsu
    case virtualHID

    static let defaultsKey = "WaveBird.outputBackend"

    static var configured: OutputBackend {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(OutputBackend.init(rawValue:)) ?? .virtualHID
    }
}

enum DSUPadKey: Hashable, Sendable {
    case solo(String)
    case joyConPair(String, String)

    private var stableIdentifier: String {
        switch self {
        case .solo(let identity): "solo:\(identity)"
        case .joyConPair(let left, let right): "pair:\(left)|\(right)"
        }
    }

    var macAddress: Data {
        var bytes = Array(SHA256.hash(data: Data(stableIdentifier.utf8)).prefix(6))
        bytes[0] = (bytes[0] & 0xFE) | 0x02 // locally administered unicast address
        return Data(bytes)
    }
}

struct DSUSlotSnapshot: Sendable {
    let key: DSUPadKey
    let index: UInt8
    let macAddress: Data
    var state: ControllerState
    var motionTimestampMicros: UInt64

    var portInfo: DSUPortInfo { DSUPortInfo(macAddress: macAddress) }
}

final class DSUOutput: @unchecked Sendable {
    private struct Registry: Sendable {
        var slots: [DSUPadKey: DSUSlotSnapshot] = [:]
        var devicePads: [DeviceID: DSUPadKey] = [:]
    }

    let backend: OutputBackend
    let server: DSUServer
    private let registry = OSAllocatedUnfairLock(initialState: Registry())

    init(backend: OutputBackend = .configured, server: DSUServer = DSUServer()) {
        self.backend = backend
        self.server = server
    }

    @discardableResult
    func start() -> Bool { server.start() }

    func stop() { server.stop() }

    @discardableResult
    func attach(_ key: DSUPadKey, devices: [DeviceID]) -> Bool {
        let snapshot = registry.withLock { state -> DSUSlotSnapshot? in
            let slot: UInt8
            if let existing = state.slots[key] {
                slot = existing.index
            } else {
                let used = Set(state.slots.values.map(\.index))
                guard let available = (0..<4).map({ UInt8($0) }).first(where: { !used.contains($0) }) else {
                    return nil
                }
                slot = available
            }

            let current = state.slots[key] ?? DSUSlotSnapshot(
                key: key,
                index: slot,
                macAddress: key.macAddress,
                state: .zero,
                motionTimestampMicros: DispatchTime.now().uptimeNanoseconds / 1_000
            )
            for device in devices { state.devicePads[device] = key }
            state.slots[key] = current
            return current
        }
        guard let snapshot else { return false }
        server.updateSlot(snapshot)
        return true
    }

    func release(_ key: DSUPadKey) {
        let removed = registry.withLock { state -> UInt8? in
            guard let snapshot = state.slots.removeValue(forKey: key) else {
                state.devicePads = state.devicePads.filter { $0.value != key }
                return nil
            }
            state.devicePads = state.devicePads.filter { $0.value != key }
            return snapshot.index
        }
        if let removed { server.removeSlot(removed) }
    }

    func release(device: DeviceID) {
        let key = registry.withLock { $0.devicePads[device] }
        if let key { release(key) }
    }

    func publish(_ state: ControllerState, for key: DSUPadKey) {
        let snapshot = registry.withLock { registry -> DSUSlotSnapshot? in
            guard var current = registry.slots[key] else { return nil }
            // Ryubing uses this timestamp for gyro integration; include gyro-only updates.
            if current.state.imu != state.imu {
                let now = DispatchTime.now().uptimeNanoseconds / 1_000
                current.motionTimestampMicros = max(now, current.motionTimestampMicros &+ 1)
            }
            current.state = state
            registry.slots[key] = current
            return current
        }
        if let snapshot { server.publish(snapshot) }
    }

    func publish(_ state: ControllerState, for device: DeviceID) {
        guard let key = registry.withLock({ $0.devicePads[device] }) else { return }
        publish(state, for: key)
    }

    func key(for device: DeviceID) -> DSUPadKey? {
        registry.withLock { $0.devicePads[device] }
    }

    func snapshot(for key: DSUPadKey) -> DSUSlotSnapshot? {
        registry.withLock { $0.slots[key] }
    }

    var padCount: Int {
        registry.withLock { $0.slots.count }
    }
}
