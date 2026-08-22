import Foundation

/// Compresses payloads for wiiload using the system's real zlib (linked via
/// the bridging header), calling `compress2` exactly as devkitPro's reference
/// `wiiload.c` does. This produces a genuine RFC 1950 zlib stream rather than
/// a hand-reconstructed one.
enum ZlibStream {

    enum ZlibError: Error {
        case compressionFailed(Int32)
    }

    static func deflate(_ source: Data, level: Int32 = 6) throws -> Data {
        guard !source.isEmpty else { return Data() }

        var destLen = uLongf(compressBound(uLong(source.count)))
        var destBuffer = [UInt8](repeating: 0, count: Int(destLen))

        let result = source.withUnsafeBytes { srcRaw -> Int32 in
            let srcPointer = srcRaw.bindMemory(to: UInt8.self).baseAddress
            return destBuffer.withUnsafeMutableBufferPointer { destBuf -> Int32 in
                compress2(destBuf.baseAddress, &destLen, srcPointer, uLong(source.count), level)
            }
        }

        guard result == Z_OK else { throw ZlibError.compressionFailed(result) }
        return Data(destBuffer[0..<Int(destLen)])
    }
}
