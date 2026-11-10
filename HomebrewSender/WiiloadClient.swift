import Foundation
import Network

/// Implements the wiiload TCP protocol (as used by devkitPro's `wiiload` and the
/// Homebrew Channel's network loader): connect to port 4299, send a 16-byte
/// header describing the payload, followed by a zlib-compressed copy of the
/// file, followed by an (empty, here) null-separated argument buffer.
final class WiiloadClient {

    enum SendError: LocalizedError {
        case invalidAddress
        case connectionFailed(String)
        case compressionFailed

        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                return "Enter a valid IP address."
            case .connectionFailed(let message):
                return "Connection failed: \(message)"
            case .compressionFailed:
                return "Could not compress the file for sending."
            }
        }
    }

    enum Progress {
        case connecting
        case sending(fraction: Double)
        case finished
    }

    static let defaultPort: UInt16 = 4299
    private static let versionMajor: UInt8 = 0
    private static let versionMinor: UInt8 = 5
    private static let chunkSize = 128 * 1024

    private var connection: NWConnection?

    /// Builds the null-separated argument buffer exactly like the Android app:
    /// `filename\0` followed by each space-separated argument and a `\0`.
    static func argumentBuffer(fileName: String, arguments: String) -> Data {
        var buffer = Data(fileName.utf8)
        buffer.append(0)
        for arg in arguments.split(whereSeparator: { $0 == " " }) {
            buffer.append(contentsOf: Array(arg.utf8))
            buffer.append(0)
        }
        return buffer
    }

    func send(fileData: Data, fileName: String, arguments: String, to host: String, port: UInt16,
              progress: @escaping (Progress) -> Void) async throws {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw SendError.invalidAddress
        }
        let host = host.trimmingCharacters(in: .whitespaces)
        let argBuffer = Self.argumentBuffer(fileName: fileName, arguments: arguments)

        let compressed: Data
        do {
            compressed = try ZlibStream.deflate(fileData)
        } catch {
            throw SendError.compressionFailed
        }

        var header = Data()
        header.append(contentsOf: Array("HAXX".utf8))
        header.append(Self.versionMajor)
        header.append(Self.versionMinor)
        header.append(contentsOf: bigEndianBytes(UInt16(min(argBuffer.count, Int(UInt16.max)))))   // argument buffer length
        header.append(contentsOf: bigEndianBytes(UInt32(compressed.count)))
        header.append(contentsOf: bigEndianBytes(UInt32(fileData.count)))

        let endpoint = NWEndpoint.Host(host)
        let params = NWParameters.tcp
        let connection = NWConnection(host: endpoint, port: nwPort, using: params)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !didResume {
                        didResume = true
                        continuation.resume()
                    }
                case .failed(let error):
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: SendError.connectionFailed(error.localizedDescription))
                    }
                case .cancelled:
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: SendError.connectionFailed("Connection cancelled."))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        progress(.connecting)

        try await sendAll(header, on: connection)
        try await sendChunked(compressed, on: connection, progress: progress)

        try await sendAll(argBuffer, on: connection)

        progress(.finished)
        connection.cancel()
        self.connection = nil
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }

    private func sendChunked(_ data: Data, on connection: NWConnection, progress: @escaping (Progress) -> Void) async throws {
        guard !data.isEmpty else { return }
        var offset = 0
        let total = data.count
        while offset < total {
            let end = min(offset + Self.chunkSize, total)
            let chunk = data.subdata(in: offset..<end)
            try await sendAll(chunk, on: connection)
            offset = end
            progress(.sending(fraction: Double(offset) / Double(total)))
        }
    }

    private func sendAll(_ data: Data, on connection: NWConnection) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: SendError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }

    private func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }

    // MARK: - 3dslink / nxlink protocol

    /// Sends a file using the netloader protocol shared by 3dslink (3DS, port 17491)
    /// and nxlink (Switch, port 28280): name length + name + size, wait for status,
    /// then zlib data as length-prefixed chunks, wait for status, then the argument buffer.
    func sendLink(fileData: Data, fileName: String, platform: Platform, arguments: String, to host: String, port: UInt16,
                  progress: @escaping (Progress) -> Void) async throws {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { throw SendError.invalidAddress }

        let compressed: Data
        do { compressed = try ZlibStream.deflate(fileData) } catch { throw SendError.compressionFailed }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = connection
        try await connect(connection)
        progress(.connecting)

        let nameBytes = Data(fileName.utf8)
        var head = Data()
        head.append(contentsOf: le32(UInt32(nameBytes.count)))
        head.append(nameBytes)
        head.append(contentsOf: le32(UInt32(fileData.count)))
        try await sendAll(head, on: connection)

        let status = try await receiveInt32LE(on: connection)
        if status != 0 {
            connection.cancel()
            let reason: String
            switch status {
            case -1: reason = "the console couldn't create the file"
            case -2: reason = "the console has insufficient space"
            case -3: reason = "the console has insufficient memory"
            default: reason = "error code \(status)"
            }
            throw SendError.connectionFailed("Rejected: \(reason).")
        }

        let chunk = 16 * 1024
        var offset = 0
        while offset < compressed.count {
            let end = min(offset + chunk, compressed.count)
            var packet = Data(le32(UInt32(end - offset)))
            packet.append(compressed.subdata(in: offset..<end))
            try await sendAll(packet, on: connection)
            offset = end
            progress(.sending(fraction: Double(offset) / Double(compressed.count)))
        }

        _ = try await receiveInt32LE(on: connection)

        // Argument buffer: 3dslink prepends argv[0]; nxlink sends only the user's arguments.
        var args = Data()
        if platform == .ds3 {
            args.append(Data("sdmc:/3ds/\(fileName)".utf8)); args.append(0)
        }
        for arg in arguments.split(whereSeparator: { $0 == " " }) {
            args.append(Data(arg.utf8)); args.append(0)
        }
        var tail = Data(le32(UInt32(args.count)))
        tail.append(args)
        try await sendAll(tail, on: connection)

        progress(.finished)
        connection.cancel()
        self.connection = nil
    }

    private func connect(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            connection.stateUpdateHandler = { state in
                guard !didResume else { return }
                switch state {
                case .ready:
                    didResume = true; continuation.resume()
                case .failed(let error):
                    didResume = true; continuation.resume(throwing: SendError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    didResume = true; continuation.resume(throwing: SendError.connectionFailed("Connection cancelled."))
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func receiveInt32LE(on connection: NWConnection) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: SendError.connectionFailed(error.localizedDescription))
                } else if let data, data.count == 4 {
                    let v = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
                    continuation.resume(returning: Int32(bitPattern: v))
                } else {
                    continuation.resume(throwing: SendError.connectionFailed("No response from the console."))
                }
            }
        }
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    // MARK: - LAN discovery
    // Probes every host on the device's Wi-Fi subnet (using the real netmask) for an
    // open listener on the platform's port. TCP probing needs no special entitlements,
    // unlike UDP broadcast discovery.

    /// All usable host addresses on the Wi-Fi/Ethernet subnet (capped to a /22), excluding our own.
    static func localSubnetHosts() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var best: (name: String, ip: UInt32, mask: UInt32)?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, let nm = ifa.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if (ip >> 16) == 0xA9FE { continue } // link-local
            if best == nil || name == "en0" { best = (name, ip, mask) }
            if name == "en0" { break }
        }
        guard let b = best else { return [] }
        var mask = b.mask
        if mask.nonzeroBitCount < 22 { mask = 0xFFFF_FC00 }
        let network = b.ip & mask
        let broadcast = network | ~mask
        guard broadcast > network + 1 else { return [] }
        var hosts: [String] = []
        // Probe neighbours of our own address first: consoles often get nearby DHCP leases.
        for h in (network + 1)..<broadcast where h != b.ip {
            hosts.append("\(h >> 24).\((h >> 16) & 255).\((h >> 8) & 255).\(h & 255)")
        }
        return hosts
    }

    /// Scans the local subnet for a listener on `port`. Returns the first match.
    static func scan(port: UInt16, timeout: TimeInterval = 1.5) async -> String? {
        let hosts = localSubnetHosts()
        guard !hosts.isEmpty else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            var iterator = hosts.makeIterator()
            let maxConcurrent = 96
            for _ in 0..<maxConcurrent {
                guard let ip = iterator.next() else { break }
                group.addTask { await probe(host: ip, port: port, timeout: timeout) ? ip : nil }
            }
            while let result = await group.next() {
                if let ip = result {
                    group.cancelAll()
                    return ip
                }
                if let ip = iterator.next() {
                    group.addTask { await probe(host: ip, port: port, timeout: timeout) ? ip : nil }
                }
            }
            return nil
        }
    }

    private static func probe(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var done = false
            func finish(_ ok: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                connection.cancel()
                continuation.resume(returning: ok)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
