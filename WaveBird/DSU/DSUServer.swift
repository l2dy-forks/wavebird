import Darwin
import Dispatch
import Foundation

final class DSUServer: @unchecked Sendable {
    static let host = "127.0.0.1"
    static let port: UInt16 = 26760
    static let clientTimeout: Duration = .seconds(5)

    private struct ClientAddress: Hashable {
        let address: UInt32
        let port: UInt16

        init(_ address: sockaddr_in) {
            self.address = address.sin_addr.s_addr
            self.port = UInt16(bigEndian: address.sin_port)
        }

        var socketAddress: sockaddr_in {
            var value = sockaddr_in()
            value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.sin_family = sa_family_t(AF_INET)
            value.sin_port = port.bigEndian
            value.sin_addr = in_addr(s_addr: address)
            return value
        }
    }

    private enum Subscription: Hashable {
        case all
        case slot(UInt8)
        case mac(Data)
    }

    private struct Client {
        var lastRequest: ContinuousClock.Instant
        var subscriptions: Set<Subscription>
        var sequence: UInt32 = 0
    }

    private let queue = DispatchQueue(label: "wavebird.dsu.server")
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timeoutSource: DispatchSourceTimer?
    private var serverID: UInt32 = UInt32.random(in: .min ... .max)
    private var clients: [ClientAddress: Client] = [:]
    private var slots: [UInt8: DSUSlotSnapshot] = [:]

    @discardableResult
    func start() -> Bool {
        queue.sync {
            guard socketFD < 0 else { return true }
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                stderrLog("[dsu] socket creation failed: \(String(cString: strerror(errno)))")
                return false
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = Self.port.bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0x7F00_0001).bigEndian)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                stderrLog("[dsu] couldn't bind to \(Self.host):\(Self.port): \(message)")
                return false
            }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                let message = String(cString: strerror(errno))
                Darwin.close(fd)
                stderrLog("[dsu] couldn't configure UDP socket: \(message)")
                return false
            }

            socketFD = fd
            serverID = UInt32.random(in: .min ... .max)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.receiveAvailable() }
            source.resume()
            readSource = source

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.expireClients() }
            timer.resume()
            timeoutSource = timer
            stderrLog("[dsu] listening on \(Self.host):\(Self.port)")
            return true
        }
    }

    func stop() {
        queue.sync {
            readSource?.cancel()
            readSource = nil
            timeoutSource?.cancel()
            timeoutSource = nil
            if socketFD >= 0 {
                Darwin.close(socketFD)
                socketFD = -1
            }
            clients.removeAll()
        }
    }

    func updateSlot(_ snapshot: DSUSlotSnapshot) {
        queue.async { [weak self] in
            self?.slots[snapshot.index] = snapshot
        }
    }

    func removeSlot(_ index: UInt8) {
        queue.async { [weak self] in
            self?.slots[index] = nil
        }
    }

    func publish(_ snapshot: DSUSlotSnapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            self.slots[snapshot.index] = snapshot
            self.sendState(snapshot)
        }
    }

    private func receiveAvailable() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var remote = sockaddr_in()
            var remoteLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &remote) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, bytes.baseAddress, bytes.count, 0, $0, &remoteLength)
                    }
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno != EINTR { stderrLog("[dsu] receive failed: \(String(cString: strerror(errno)))") }
                continue
            }
            guard count > 0, remote.sin_family == sa_family_t(AF_INET) else { continue }
            handle(Data(buffer.prefix(count)), from: ClientAddress(remote))
        }
    }

    private func handle(_ data: Data, from address: ClientAddress) {
        guard let request = DSUProtocol.validClientPacket(data) else { return }
        switch request.message {
        case DSUProtocol.messageVersion:
            send(DSUProtocol.versionResponse(serverID: serverID), to: address)
        case DSUProtocol.messagePorts:
            handlePortInfo(request.payload, from: address)
        case DSUProtocol.messageData:
            register(request.payload, from: address)
        default:
            break
        }
    }

    private func handlePortInfo(_ payload: Data, from address: ClientAddress) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { return }
        let rawCount = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        let count = Int(Int32(bitPattern: rawCount))
        guard (0...4).contains(count), bytes.count >= 4 + count else { return }
        for slot in bytes[4..<(4 + count)] where slot < 4 {
            send(DSUProtocol.portInfoResponse(slot: slot, info: slots[slot]?.portInfo, serverID: serverID), to: address)
        }
    }

    private func register(_ payload: Data, from address: ClientAddress) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { return }
        let flags = bytes[0]
        var subscriptions = Set<Subscription>()
        if flags == 0 {
            subscriptions.insert(.all)
        } else {
            if flags & 0x01 != 0, bytes[1] < 4 {
                subscriptions.insert(.slot(bytes[1]))
            }
            if flags & 0x02 != 0 {
                subscriptions.insert(.mac(Data(bytes[2..<8])))
            }
        }
        guard !subscriptions.isEmpty else { return }

        let now = ContinuousClock.now
        if var client = clients[address] {
            client.lastRequest = now
            client.subscriptions.formUnion(subscriptions)
            clients[address] = client
        } else {
            clients[address] = Client(lastRequest: now, subscriptions: subscriptions)
        }
        sendCurrentStates(to: address)
    }

    private func sendCurrentStates(to address: ClientAddress) {
        guard let client = clients[address] else { return }
        let subscribed = slots.values
            .filter { matches(client.subscriptions, snapshot: $0) }
            .sorted { $0.index < $1.index }
        for snapshot in subscribed { sendState(snapshot, to: address) }
    }

    private func sendState(_ snapshot: DSUSlotSnapshot) {
        let targets = clients.keys.filter { address in
            guard let client = clients[address] else { return false }
            return matches(client.subscriptions, snapshot: snapshot)
        }
        for address in targets { sendState(snapshot, to: address) }
    }

    private func sendState(_ snapshot: DSUSlotSnapshot, to address: ClientAddress) {
        guard var client = clients[address] else { return }
        client.sequence &+= 1
        let sequence = client.sequence
        clients[address] = client
        let packet = DSUProtocol.dataResponse(
            slot: snapshot.index,
            info: snapshot.portInfo,
            state: snapshot.state,
            sequence: sequence,
            timestampMicros: snapshot.motionTimestampMicros,
            serverID: serverID
        )
        send(packet, to: address)
    }

    private func matches(_ subscriptions: Set<Subscription>, snapshot: DSUSlotSnapshot) -> Bool {
        subscriptions.contains(.all)
            || subscriptions.contains(.slot(snapshot.index))
            || subscriptions.contains(.mac(snapshot.macAddress))
    }

    private func send(_ packet: Data, to address: ClientAddress) {
        guard socketFD >= 0 else { return }
        var remote = address.socketAddress
        let result = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &remote) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if result < 0, errno != EAGAIN, errno != EWOULDBLOCK {
            stderrLog("[dsu] send failed: \(String(cString: strerror(errno)))")
        }
    }

    private func expireClients() {
        let now = ContinuousClock.now
        clients = clients.filter { now - $0.value.lastRequest < Self.clientTimeout }
    }
}
