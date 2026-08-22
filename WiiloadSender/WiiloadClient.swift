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

    private static let port: NWEndpoint.Port = 4299
    private static let versionMajor: UInt8 = 0
    private static let versionMinor: UInt8 = 5
    private static let chunkSize = 128 * 1024

    private var connection: NWConnection?

    func send(fileData: Data, to host: String, progress: @escaping (Progress) -> Void) async throws {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SendError.invalidAddress
        }

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
        header.append(contentsOf: bigEndianBytes(UInt16(0)))               // argument buffer length (no args)
        header.append(contentsOf: bigEndianBytes(UInt32(compressed.count)))
        header.append(contentsOf: bigEndianBytes(UInt32(fileData.count)))

        let endpoint = NWEndpoint.Host(host)
        let params = NWParameters.tcp
        let connection = NWConnection(host: endpoint, port: Self.port, using: params)
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
}
